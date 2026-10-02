"""Outcome-feedback dataset construction with publication-time leakage controls."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
import math
from statistics import median
from typing import Any


NUMERIC_FEATURES = (
    "semantic.hook_strength", "semantic.standalone_clarity", "semantic.information_density",
    "semantic.novelty", "semantic.emotional_intensity", "semantic.quotability",
    "semantic.payoff_strength", "semantic.story_completeness", "semantic.technical_depth",
    "semantic.call_to_action_presence", "audio.words_per_minute", "audio.average_audio_energy",
    "audio.energy_variance", "audio.energy_change_at_hook", "audio.silence_ratio",
    "audio.longest_pause_ms", "audio.pause_frequency", "visual.face_presence_ratio",
    "visual.visual_motion", "visual.scene_change_rate", "visual.screen_recording_ratio",
    "visual.camera_change_frequency", "visual.sample_count", "structural.time_to_main_point_ms",
    "structural.intro_length_ms", "structural.sentence_completeness",
    "structural.hook_to_payoff_time_ms", "structural.dead_air_start_ms",
    "structural.dead_air_end_ms",
)
CATEGORICAL_FEATURES = ("semantic.topic", "semantic.content_type", "semantic.hook_type")
ALL_FEATURES = NUMERIC_FEATURES + CATEGORICAL_FEATURES


@dataclass(frozen=True)
class Example:
    publication_id: str
    account_id: str
    source_video_id: str
    published_at: datetime
    snapshot_id: str
    observed_at: datetime
    post_age_hours: float
    views: int
    baseline_score: float
    features: dict[str, float | str]
    account_baseline: float
    baseline_source: str
    baseline_snapshot_ids: tuple[str, ...]
    target: float


@dataclass(frozen=True)
class Dataset:
    examples: list[Example]
    exclusions: list[dict[str, str]]
    manifest: dict[str, Any]


def flatten_features(payload: dict[str, Any]) -> dict[str, float | str]:
    if not isinstance(payload, dict):
        raise ValueError("features must be an object")
    if all(path in payload for path in ALL_FEATURES):
        return {path: payload[path] for path in ALL_FEATURES}
    flattened: dict[str, float | str] = {}
    for path in NUMERIC_FEATURES:
        group, name = path.split(".", 1)
        value = payload.get(group, {}).get(name) if isinstance(payload.get(group), dict) else None
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
            raise ValueError(f"missing or invalid numeric feature {path}")
        flattened[path] = float(value)
    for path in CATEGORICAL_FEATURES:
        group, name = path.split(".", 1)
        value = payload.get(group, {}).get(name) if isinstance(payload.get(group), dict) else None
        if not isinstance(value, str) or not value:
            raise ValueError(f"missing or invalid categorical feature {path}")
        flattened[path] = value
    return flattened


def _valid_snapshots(publication: Any, request: Any) -> list[tuple[Any, float]]:
    aged = [
        (snapshot, (snapshot.observed_at - publication.published_at).total_seconds() / 3600.0)
        for snapshot in publication.snapshots
    ]
    return [
        (snapshot, actual_age) for snapshot, actual_age in aged
        if request.maturity_min_hours <= actual_age <= request.maturity_max_hours
        and abs(actual_age - snapshot.post_age_hours) <= 0.05
        and snapshot.views is not None
    ]


def _closest_snapshot(snapshots: list[tuple[Any, float]], available_at: datetime | None = None):
    available = [
        item for item in snapshots
        if available_at is None or item[0].observed_at <= available_at
    ]
    if not available:
        return None
    return min(available, key=lambda item: (abs(item[1] - 72.0), item[0].observed_at))


def _history_values(history_rows: list[dict[str, Any]], current: Any, account_id: str | None = None) -> list[tuple[float, str]]:
    current_key = (current.published_at, current.publication_id)
    history: list[tuple[datetime, str, float, str]] = []
    for row in history_rows:
        publication = row["publication"]
        if (publication.published_at, publication.publication_id) >= current_key:
            continue
        if account_id is not None and publication.account_id != account_id:
            continue
        selected = _closest_snapshot(row["valid_snapshots"], available_at=current.published_at)
        if selected is None:
            continue
        snapshot, _actual_age = selected
        history.append((
            publication.published_at, publication.publication_id,
            math.log1p(snapshot.views), snapshot.snapshot_id,
        ))
    history.sort(key=lambda item: (item[0], item[1]))
    return [(item[2], item[3]) for item in history]


def build_dataset(request: Any) -> Dataset:
    selected: list[dict[str, Any]] = []
    history_rows: list[dict[str, Any]] = []
    exclusions: list[dict[str, str]] = []
    for publication in request.publications:
        valid = _valid_snapshots(publication, request)
        if valid:
            history_rows.append({"publication": publication, "valid_snapshots": valid})
        if publication.schema_version != request.feature_schema_version:
            exclusions.append({"publication_id": publication.publication_id, "reason": "schema_mismatch"})
            continue
        if not valid:
            aged_snapshots = [
                (snapshot, (snapshot.observed_at - publication.published_at).total_seconds() / 3600.0)
                for snapshot in publication.snapshots
            ]
            if any(abs(actual_age - snapshot.post_age_hours) > 0.05 for snapshot, actual_age in aged_snapshots):
                reason = "snapshot_age_mismatch"
            elif any(snapshot.views is None for snapshot in publication.snapshots):
                reason = "missing_views"
            else:
                reason = "immature_or_outside_tolerance"
            exclusions.append({"publication_id": publication.publication_id, "reason": reason})
            continue
        outcome, actual_age = _closest_snapshot(valid)
        try:
            features = flatten_features(publication.features)
        except ValueError as error:
            exclusions.append({"publication_id": publication.publication_id, "reason": str(error)})
            continue
        selected.append({"publication": publication, "snapshot": outcome, "actual_age": actual_age, "features": features})

    selected.sort(key=lambda row: (row["publication"].published_at, row["publication"].publication_id))
    examples: list[Example] = []
    for row in selected:
        publication = row["publication"]
        snapshot = row["snapshot"]
        account_history = _history_values(history_rows, publication, account_id=publication.account_id)
        platform_history = _history_values(history_rows, publication)
        if len(account_history) >= request.minimum_account_history:
            baseline_history = account_history[-request.account_history_window:]
            baseline_source = "account_trailing_median"
        elif platform_history:
            baseline_history = platform_history[-max(request.account_history_window, request.minimum_account_history):]
            baseline_source = "platform_trailing_median"
        else:
            baseline_history = [(0.0, "zero_history_cold_start")]
            baseline_source = "zero_history_cold_start"
        baseline_values = [item[0] for item in baseline_history]
        account_baseline = float(median(baseline_values))
        log_views = math.log1p(snapshot.views)
        examples.append(Example(
            publication_id=publication.publication_id,
            account_id=publication.account_id,
            source_video_id=publication.source_video_id,
            published_at=publication.published_at,
            snapshot_id=snapshot.snapshot_id,
            observed_at=snapshot.observed_at,
            post_age_hours=row["actual_age"],
            views=snapshot.views,
            baseline_score=publication.baseline_score,
            features=row["features"],
            account_baseline=account_baseline,
            baseline_source=baseline_source,
            baseline_snapshot_ids=tuple(item[1] for item in baseline_history if baseline_source != "zero_history_cold_start"),
            target=log_views - account_baseline,
        ))

    identity = [{"publication_id": item.publication_id, "snapshot_id": item.snapshot_id} for item in examples]
    reproducible_rows = [
        {
            "publication_id": item.publication_id,
            "snapshot_id": item.snapshot_id,
            "account_id": item.account_id,
            "source_video_id": item.source_video_id,
            "published_at": item.published_at.isoformat(),
            "observed_at": item.observed_at.isoformat(),
            "views": item.views,
            "baseline_score": item.baseline_score,
            "account_baseline": item.account_baseline,
            "baseline_source": item.baseline_source,
            "baseline_snapshot_ids": item.baseline_snapshot_ids,
            "target": item.target,
            "features": item.features,
        }
        for item in examples
    ]
    digest = hashlib.sha256(json.dumps(reproducible_rows, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    manifest = {
        "dataset_sha256": digest,
        "eligible_count": len(examples),
        "excluded_count": len(exclusions),
        "publication_snapshot_ids": identity,
        "baseline_snapshot_ids_by_publication": [
            {"publication_id": item.publication_id, "snapshot_ids": list(item.baseline_snapshot_ids)}
            for item in examples
        ],
        "exclusions": exclusions,
        "label_policy_version": request.label_policy_version,
        "feature_schema_version": request.feature_schema_version,
        "maturity_tolerance_hours": [request.maturity_min_hours, request.maturity_max_hours],
        "logical_feature_count": len(ALL_FEATURES),
    }
    return Dataset(examples=examples, exclusions=exclusions, manifest=manifest)
