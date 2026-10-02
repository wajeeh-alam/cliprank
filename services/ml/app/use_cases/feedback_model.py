"""Train, evaluate and serve the transparent regularized feedback model."""

from __future__ import annotations

from collections import defaultdict
from datetime import timezone
import hashlib
import json
import math
from typing import Any

import numpy as np
from scipy.stats import spearmanr
from sklearn.linear_model import Ridge
from sklearn.metrics import mean_absolute_error, mean_squared_error
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from app.api.feedback_schemas import FeedbackScoreRequest, FeedbackTrainRequest
from app.domain.errors import ServiceError
from app.domain.feedback import CATEGORICAL_FEATURES, NUMERIC_FEATURES, Dataset, Example, build_dataset, flatten_features


def _partition(dataset: Dataset) -> tuple[list[Example], list[Example], list[Example], list[str], list[str]]:
    examples = dataset.examples
    if len(examples) < 10:
        return examples, [], [], [], []
    train_cutoff = examples[max(0, int(len(examples) * 0.6) - 1)].published_at
    validation_cutoff = examples[max(0, int(len(examples) * 0.8) - 1)].published_at
    group_ranges: dict[str, tuple[Any, Any]] = {}
    for item in examples:
        current = group_ranges.get(item.source_video_id)
        group_ranges[item.source_video_id] = (
            min(current[0], item.published_at) if current else item.published_at,
            max(current[1], item.published_at) if current else item.published_at,
        )
    purged = {
        group for group, (start, finish) in group_ranges.items()
        if start <= train_cutoff < finish or start <= validation_cutoff < finish
    }
    train = [item for item in examples if item.source_video_id not in purged and item.published_at <= train_cutoff]
    validation = [item for item in examples if item.source_video_id not in purged and train_cutoff < item.published_at <= validation_cutoff]
    test = [item for item in examples if item.source_video_id not in purged and item.published_at > validation_cutoff]
    evaluation = validation + test
    evaluation_start = min((item.published_at for item in evaluation), default=None)
    unavailable = [] if evaluation_start is None else [item for item in train if item.observed_at > evaluation_start]
    unavailable_ids = {item.publication_id for item in unavailable}
    train = [item for item in train if item.publication_id not in unavailable_ids]
    return train, validation, test, sorted(purged), sorted(unavailable_ids)


def _fit(examples: list[Example]):
    numeric = np.asarray([[float(item.features[name]) for name in NUMERIC_FEATURES] for item in examples], dtype=float)
    categorical = np.asarray([[str(item.features[name]) for name in CATEGORICAL_FEATURES] for item in examples], dtype=object)
    target = np.asarray([item.target for item in examples], dtype=float)
    scaler = StandardScaler().fit(numeric)
    encoder = OneHotEncoder(handle_unknown="ignore", sparse_output=False).fit(categorical)
    matrix = np.hstack([scaler.transform(numeric), encoder.transform(categorical)])
    model = Ridge(alpha=1.0).fit(matrix, target)
    return scaler, encoder, model


def _artifact(schema_version: str, scaler: StandardScaler, encoder: OneHotEncoder, model: Ridge) -> dict[str, Any]:
    categories = {name: [str(value) for value in values] for name, values in zip(CATEGORICAL_FEATURES, encoder.categories_, strict=True)}
    encoded_names = list(NUMERIC_FEATURES)
    for name in CATEGORICAL_FEATURES:
        encoded_names.extend(f"{name}={value}" for value in categories[name])
    return {
        "artifact_version": "feedback-linear-artifact-1",
        "algorithm": "standard-scaler-one-hot-ridge",
        "feature_schema_version": schema_version,
        "numeric_features": list(NUMERIC_FEATURES),
        "categorical_features": list(CATEGORICAL_FEATURES),
        "numeric_mean": scaler.mean_.tolist(),
        "numeric_scale": scaler.scale_.tolist(),
        "categories": categories,
        "encoded_feature_names": encoded_names,
        "coefficients": model.coef_.tolist(),
        "intercept": float(model.intercept_),
        "ridge_alpha": float(model.alpha),
    }


def artifact_digest(artifact: dict[str, Any]) -> str:
    return hashlib.sha256(json.dumps(artifact, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _encoded_row(features: dict[str, Any], artifact: dict[str, Any]) -> tuple[np.ndarray, list[str]]:
    flattened = flatten_features(features)
    numeric_names = artifact["numeric_features"]
    means = artifact["numeric_mean"]
    scales = artifact["numeric_scale"]
    values = [(float(flattened[name]) - float(mean)) / (float(scale) or 1.0) for name, mean, scale in zip(numeric_names, means, scales, strict=True)]
    names = list(numeric_names)
    for name in artifact["categorical_features"]:
        actual = str(flattened[name])
        for category in artifact["categories"][name]:
            values.append(1.0 if actual == category else 0.0)
            names.append(f"{name}={category}")
    return np.asarray(values, dtype=float), names


def _predict(features: dict[str, Any], artifact: dict[str, Any]) -> tuple[float, list[dict[str, Any]]]:
    row, names = _encoded_row(features, artifact)
    coefficients = np.asarray(artifact["coefficients"], dtype=float)
    if len(row) != len(coefficients):
        raise ValueError("artifact coefficient count does not match preprocessing output")
    contributions = row * coefficients
    prediction = float(artifact["intercept"] + contributions.sum())
    grouped: dict[str, float] = defaultdict(float)
    for name, value in zip(names, contributions, strict=True):
        source = name.split("=", 1)[0]
        grouped[source] += float(value)
    ranked = sorted(grouped.items(), key=lambda item: (-abs(item[1]), item[0]))[:8]
    return prediction, [{"feature": name, "contribution": round(value, 8)} for name, value in ranked]


def _correlation(scores: list[float], targets: list[float]) -> float | None:
    if len(scores) < 2 or len(set(scores)) < 2 or len(set(targets)) < 2:
        return None
    value = float(spearmanr(scores, targets).statistic)
    return value if math.isfinite(value) else None


def _evaluate(examples: list[Example], artifact: dict[str, Any]) -> dict[str, Any]:
    if not examples:
        return {"sample_count": 0, "baseline_spearman": None, "feedback_spearman": None, "spearman_delta": None, "mae": None, "rmse": None}
    predicted = [_predict(item.features, artifact)[0] for item in examples]
    targets = [item.target for item in examples]
    baseline = [item.baseline_score for item in examples]
    baseline_rho = _correlation(baseline, targets)
    feedback_rho = _correlation(predicted, targets)
    delta = feedback_rho - baseline_rho if feedback_rho is not None and baseline_rho is not None else None
    return {
        "sample_count": len(examples),
        "baseline_spearman": baseline_rho,
        "feedback_spearman": feedback_rho,
        "spearman_delta": delta,
        "mae": float(mean_absolute_error(targets, predicted)),
        "rmse": float(mean_squared_error(targets, predicted) ** 0.5),
    }


def train(request: FeedbackTrainRequest) -> dict[str, Any]:
    dataset = build_dataset(request)
    if len(dataset.examples) < 2:
        raise ServiceError("INSUFFICIENT_FEEDBACK_DATA", "At least two valid mature outcomes are required to train.", retryable=False, details=dataset.manifest, status_code=422)
    train_examples, validation_examples, test_examples, purged_groups, unavailable_training = _partition(dataset)
    if len(train_examples) < 2:
        details = dict(dataset.manifest)
        details.update({
            "purged_source_video_ids": purged_groups,
            "purged_unavailable_training_publication_ids": unavailable_training,
        })
        raise ServiceError(
            "INSUFFICIENT_CHRONOLOGICAL_TRAINING_DATA",
            "At least two training outcomes must be observable before the held-out evaluation window begins.",
            retryable=False,
            details=details,
            status_code=422,
        )
    scaler, encoder, model = _fit(train_examples)
    artifact = _artifact(request.feature_schema_version, scaler, encoder, model)
    digest = artifact_digest(artifact)
    validation = _evaluate(validation_examples, artifact)
    final_test = _evaluate(test_examples, artifact)
    enough_data = len(train_examples) >= 20 and len(validation_examples) >= 5 and len(test_examples) >= 5
    repeatable_improvement = (
        enough_data and validation["spearman_delta"] is not None and final_test["spearman_delta"] is not None
        and validation["spearman_delta"] > 0 and final_test["spearman_delta"] > 0
    )
    training_cutoff = max(item.published_at for item in train_examples).astimezone(timezone.utc)
    held_out_examples = validation_examples + test_examples
    evaluation_start = min((item.published_at for item in held_out_examples), default=None)
    manifest = dict(dataset.manifest)
    manifest.update({
        "training_publication_ids": [item.publication_id for item in train_examples],
        "validation_publication_ids": [item.publication_id for item in validation_examples],
        "final_test_publication_ids": [item.publication_id for item in test_examples],
        "purged_source_video_ids": purged_groups,
        "purged_unavailable_training_publication_ids": unavailable_training,
        "evaluation_window_started_at": evaluation_start.astimezone(timezone.utc).isoformat() if evaluation_start else None,
        "latest_training_label_observed_at": max(item.observed_at for item in train_examples).astimezone(timezone.utc).isoformat(),
    })
    version_identity = {
        "artifact_sha256": digest,
        "dataset_sha256": manifest["dataset_sha256"],
        "training_publication_ids": manifest["training_publication_ids"],
        "validation_publication_ids": manifest["validation_publication_ids"],
        "final_test_publication_ids": manifest["final_test_publication_ids"],
        "training_cutoff": training_cutoff.isoformat(),
    }
    version_digest = hashlib.sha256(json.dumps(version_identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    version = f"feedback-linear-{version_digest[:12]}"
    return {
        "model_version": version,
        "algorithm": artifact["algorithm"],
        "artifact": artifact,
        "artifact_sha256": digest,
        "training_cutoff": training_cutoff.isoformat(),
        "sample_count": len(dataset.examples),
        "evaluation_metrics": {
            "training_count": len(train_examples),
            "validation": validation,
            "final_test": final_test,
            "release_gate": {
                "eligible": bool(repeatable_improvement),
                "enough_data": bool(enough_data),
                "reason": "repeatable_held_out_improvement" if repeatable_improvement else "remain_in_shadow",
            },
        },
        "dataset_manifest": manifest,
    }


def score(request: FeedbackScoreRequest) -> dict[str, Any]:
    if request.artifact.get("feature_schema_version") != request.feature_schema_version:
        raise ServiceError("FEATURE_SCHEMA_MISMATCH", "Feedback artifact and candidate schema do not match.", retryable=False, status_code=422)
    if artifact_digest(request.artifact) != request.artifact_sha256:
        raise ServiceError("ARTIFACT_CHECKSUM_MISMATCH", "Feedback artifact checksum is invalid.", retryable=False, status_code=422)
    results = []
    try:
        for candidate in request.candidates:
            predicted, contributions = _predict(candidate.features, request.artifact)
            display = 100.0 / (1.0 + math.exp(-max(-20.0, min(20.0, predicted))))
            results.append({
                "candidate_id": candidate.candidate_id,
                "predicted_outcome": round(predicted, 8),
                "feedback_score": round(display, 4),
                "contributions": contributions,
            })
    except (KeyError, TypeError, ValueError) as error:
        raise ServiceError("FEEDBACK_SCORING_FAILED", "Feedback inputs or artifact are invalid.", retryable=False, details={"reason": str(error)}, status_code=422) from error
    results.sort(key=lambda item: (-item["predicted_outcome"], item["candidate_id"]))
    for rank, item in enumerate(results, start=1):
        item["rank"] = rank
    return {"model_version": request.model_version, "feature_schema_version": request.feature_schema_version, "ranked_candidates": results}
