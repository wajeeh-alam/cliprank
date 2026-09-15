from copy import deepcopy

import pytest
from fastapi.testclient import TestClient

from app.adapters.baseline import HeuristicRanker
from app.api.schemas import RankRequest
from app.domain.ranking import score_candidate
from app.main import app
from app.use_cases.rank_candidates import execute
from tests.conftest import feature_payload


def test_heuristic_score_is_deterministic_and_bounded():
    request = RankRequest(
        contract_version="1.0", video_id="v1", feature_version="features-1", scorer_version="heuristic-1",
        config={"weights": {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10}, "output_scale": 100},
        candidates=[feature_payload()],
    )
    result = execute(request)[0]
    assert result.rank == 1
    assert result.clip_score == 77.35
    assert 0 <= result.clip_score <= 100
    assert set(result.components) == {"content_quality", "hook", "delivery", "pacing", "visual_engagement", "standalone_clarity"}
    assert result.component_details["semantic"].weight == 0.35
    assert result.clip_score == execute(request)[0].clip_score


def test_rank_rejects_feature_version_mismatch():
    payload = feature_payload(feature_version="features-other")
    try:
        RankRequest(
            contract_version="1.0", video_id="v1", feature_version="features-1", scorer_version="heuristic-1",
            config={"weights": {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10}, "output_scale": 100},
            candidates=[payload],
        )
    except ValueError as error:
        assert "feature_version" in str(error)
    else:
        raise AssertionError("mismatched feature versions must be rejected")


def test_rank_rejects_candidate_from_another_video():
    payload = feature_payload()
    payload["features"]["video_id"] = "v2"
    try:
        RankRequest(
            contract_version="1.0", video_id="v1", feature_version="features-1", scorer_version="heuristic-1",
            config={"weights": {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10}, "output_scale": 100},
            candidates=[payload],
        )
    except ValueError as error:
        assert "video_id" in str(error)
    else:
        raise AssertionError("cross-video features must be rejected")


def test_rank_uses_documented_weights_and_rejects_weight_changes():
    with pytest.raises(ValueError, match="documented heuristic"):
        RankRequest(
            contract_version="1.0", video_id="v1", feature_version="features-1", scorer_version="heuristic-1",
            config={"weights": {"semantic": 0.40, "hook": 0.15, "structural": 0.20, "delivery": 0.15, "visual": 0.10}, "output_scale": 100},
            candidates=[feature_payload()],
        )
    with pytest.raises(ValueError, match="documented"):
        score_candidate(feature_payload()["features"], {"semantic": 0.40, "hook": 0.15, "structural": 0.20, "delivery": 0.15, "visual": 0.10})


def test_malformed_direct_features_are_rejected_or_bounded_without_nan():
    payload = feature_payload()["features"]
    payload["semantic"]["hook_strength"] = 4.0
    payload["audio"]["silence_ratio"] = -3.0
    payload["structural"]["intro_length_ms"] = 600_000
    result = score_candidate(payload)
    assert 0.0 <= result["clip_score"] <= 100.0
    assert all(0.0 <= value <= 100.0 for value in result["components"].values())
    assert all(0.0 <= details["normalized"] <= 1.0 for details in result["component_details"].values())

    payload["audio"]["average_audio_energy"] = float("nan")
    with pytest.raises(ValueError, match="finite"):
        score_candidate(payload)


def test_rank_ties_are_ordered_by_candidate_id():
    first = {"candidate_id": "candidate-b", "features": feature_payload("candidate-b")["features"]}
    second = {"candidate_id": "candidate-a", "features": feature_payload("candidate-a")["features"]}
    ranked = HeuristicRanker().rank([first, second], {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10})
    assert [candidate["candidate_id"] for candidate in ranked] == ["candidate-a", "candidate-b"]
    assert [candidate["rank"] for candidate in ranked] == [1, 2]


def test_rank_rejects_duplicate_candidate_ids():
    candidate = {"candidate_id": "same", "features": feature_payload("same")["features"]}
    with pytest.raises(ValueError, match="unique"):
        HeuristicRanker().rank([candidate, deepcopy(candidate)], {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10})


def test_rank_api_returns_ordered_bounded_envelope(headers):
    candidates = []
    for candidate_id in ("candidate-b", "candidate-a"):
        payload = feature_payload(candidate_id)
        candidates.append(payload)
    body = {
        "contract_version": "1.0", "video_id": "v1", "feature_version": "features-1", "scorer_version": "heuristic-1",
        "config": {"weights": {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10}, "output_scale": 100},
        "candidates": candidates,
    }
    response = TestClient(app).post("/internal/api/v1/rank", headers=headers, json=body)
    assert response.status_code == 200
    envelope = response.json()
    assert envelope["contract_version"] == "1.0"
    assert envelope["request_id"] == "req-test-1"
    assert envelope["idempotency_key"] == "video/1/run/1/test"
    ranked = envelope["data"]["ranked_candidates"]
    assert [candidate["candidate_id"] for candidate in ranked] == ["candidate-a", "candidate-b"]
    assert [candidate["rank"] for candidate in ranked] == [1, 2]
    assert all(0.0 <= candidate["clip_score"] <= 100.0 for candidate in ranked)


def test_rank_api_rejects_malformed_candidate_contract(headers):
    payload = feature_payload()
    payload["features"]["feature_version"] = "other-version"
    body = {
        "contract_version": "1.0", "video_id": "v1", "feature_version": "features-1", "scorer_version": "heuristic-1",
        "config": {"weights": {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10}, "output_scale": 100},
        "candidates": [payload],
    }
    response = TestClient(app).post("/internal/api/v1/rank", headers=headers, json=body)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "INVALID_REQUEST"
