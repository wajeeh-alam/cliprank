from app.api.schemas import RankRequest
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
    assert result.component_details["semantic"]["weight"] == 0.35
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
