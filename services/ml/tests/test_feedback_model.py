from copy import deepcopy
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from app.api.feedback_schemas import FeedbackTrainRequest
from app.domain.feedback import build_dataset
from app.main import app
from app.use_cases.feedback_model import _partition
from tests.conftest import feature_payload


def features(index: int = 0):
    payload = deepcopy(feature_payload(f"c-{index}")["features"])
    payload.pop("video_id")
    payload.pop("candidate_id")
    payload.pop("feature_version")
    payload.pop("model_version")
    payload.pop("prompt_version")
    payload.pop("capability_warnings")
    payload["semantic"]["hook_strength"] = min(1.0, 0.1 + index * 0.06)
    payload["semantic"]["information_density"] = min(1.0, 0.2 + index * 0.04)
    return payload


def training_body(count: int = 14):
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    publications = []
    for index in range(count):
        published_at = start + timedelta(days=index * 4)
        publications.append({
            "publication_id": f"publication-{index}",
            "account_id": f"account-{index % 2}",
            "source_video_id": f"video-{index}",
            "published_at": published_at.isoformat(),
            "features": features(index),
            "schema_version": "features-1",
            "baseline_score": float(40 + index % 5),
            "snapshots": [{
                "snapshot_id": f"snapshot-{index}",
                "observed_at": (published_at + timedelta(hours=72)).isoformat(),
                "post_age_hours": 72.0,
                "views": 100 + index * 75,
            }],
        })
    return {
        "contract_version": "1.0",
        "platform": "instagram",
        "feature_schema_version": "features-1",
        "label_policy_version": "views-72h-account-median-v1",
        "maturity_min_hours": 60.0,
        "maturity_max_hours": 84.0,
        "account_history_window": 20,
        "minimum_account_history": 5,
        "publications": publications,
    }


def test_dataset_uses_closest_mature_snapshot_and_preserves_missing_views():
    body = training_body(2)
    first = body["publications"][0]
    published = datetime.fromisoformat(first["published_at"])
    first["snapshots"] = [
        {"snapshot_id": "missing", "observed_at": (published + timedelta(hours=72)).isoformat(), "post_age_hours": 72.0, "views": None},
        {"snapshot_id": "near", "observed_at": (published + timedelta(hours=70)).isoformat(), "post_age_hours": 70.0, "views": 220},
        {"snapshot_id": "late", "observed_at": (published + timedelta(hours=90)).isoformat(), "post_age_hours": 90.0, "views": 999},
    ]
    request = FeedbackTrainRequest.model_validate(body)
    dataset = build_dataset(request)

    assert dataset.examples[0].snapshot_id == "near"
    assert dataset.examples[0].views == 220
    assert dataset.examples[0].baseline_source == "zero_history_cold_start"
    assert dataset.manifest["logical_feature_count"] == 32


def test_training_and_checksum_verified_artifact_reload(headers):
    client = TestClient(app)
    trained_response = client.post("/internal/api/v1/feedback/train", headers=headers, json=training_body())
    assert trained_response.status_code == 200, trained_response.text
    trained = trained_response.json()["data"]
    assert trained["sample_count"] == 14
    assert trained["dataset_manifest"]["eligible_count"] == 14
    assert trained["evaluation_metrics"]["final_test"]["sample_count"] > 0
    assert len(trained["artifact_sha256"]) == 64

    score_body = {
        "contract_version": "1.0",
        "feature_schema_version": "features-1",
        "model_version": trained["model_version"],
        "artifact_sha256": trained["artifact_sha256"],
        "artifact": trained["artifact"],
        "candidates": [
            {"candidate_id": "new-low", "features": features(1)},
            {"candidate_id": "new-high", "features": features(12)},
        ],
    }
    scored_response = client.post("/internal/api/v1/feedback/score", headers=headers, json=score_body)
    assert scored_response.status_code == 200, scored_response.text
    ranked = scored_response.json()["data"]["ranked_candidates"]
    assert {item["candidate_id"] for item in ranked} == {"new-low", "new-high"}
    assert [item["rank"] for item in ranked] == [1, 2]
    assert all(item["contributions"] for item in ranked)

    score_body["artifact_sha256"] = "0" * 64
    rejected = client.post("/internal/api/v1/feedback/score", headers=headers, json=score_body)
    assert rejected.status_code == 422
    assert rejected.json()["error"]["code"] == "ARTIFACT_CHECKSUM_MISMATCH"


def test_training_rejects_immature_and_schema_mismatched_rows(headers):
    body = training_body(2)
    published = datetime.fromisoformat(body["publications"][0]["published_at"])
    body["publications"][0]["snapshots"][0]["post_age_hours"] = 12.0
    body["publications"][0]["snapshots"][0]["observed_at"] = (published + timedelta(hours=12)).isoformat()
    body["publications"][1]["schema_version"] = "features-other"
    response = TestClient(app).post("/internal/api/v1/feedback/train", headers=headers, json=body)
    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "INSUFFICIENT_FEEDBACK_DATA"
    reasons = {item["reason"] for item in error["details"]["exclusions"]}
    assert "immature_or_outside_tolerance" in reasons
    assert "schema_mismatch" in reasons


def test_chronological_split_purges_source_video_that_crosses_a_boundary():
    body = training_body(12)
    body["publications"][6]["source_video_id"] = "crossing-video"
    body["publications"][7]["source_video_id"] = "crossing-video"
    dataset = build_dataset(FeedbackTrainRequest.model_validate(body))

    train, validation, final_test, purged = _partition(dataset)
    assert "crossing-video" in purged
    assert all(item.source_video_id != "crossing-video" for item in train + validation + final_test)
    assert max(item.published_at for item in train) < min(item.published_at for item in validation)
    assert max(item.published_at for item in validation) < min(item.published_at for item in final_test)
