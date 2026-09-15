from app.api.schemas import CandidateGenerationRequest
from app.use_cases.generate_candidates import execute


def test_candidate_boundaries_and_duration_policy():
    request = CandidateGenerationRequest(
        contract_version="1.0", video_id="v1", duration_ms=90000, generation_version="candidate-1",
        min_duration_ms=15000, max_duration_ms=60000, target_count_min=1, target_count_max=40,
        segments=[
            {"sequence": 0, "start_ms": 0, "end_ms": 5000, "text": "Intro."},
            {"sequence": 1, "start_ms": 5000, "end_ms": 20000, "text": "The idea starts."},
            {"sequence": 2, "start_ms": 20000, "end_ms": 40000, "text": "The idea concludes."},
        ],
    )
    candidates, warnings = execute(request)
    assert not warnings
    assert len(candidates) == 3
    candidate = candidates[0]
    assert candidate.start_ms == 0
    assert candidate.end_ms == 40000
    assert candidate.duration_ms == 40000


def test_short_source_returns_warning_without_invalid_candidate():
    request = CandidateGenerationRequest(
        contract_version="1.0", video_id="v1", duration_ms=10000, generation_version="candidate-1",
        segments=[{"sequence": 0, "start_ms": 0, "end_ms": 10000, "text": "Too short."}],
    )
    candidates, warnings = execute(request)
    assert candidates == []
    assert "SOURCE_CANNOT_SUPPORT_TARGET_CANDIDATE_COUNT" in warnings


def test_candidate_generation_caps_at_policy_max():
    segments = [{"sequence": i, "start_ms": i * 5000, "end_ms": (i + 1) * 5000, "text": f"Part {i}"} for i in range(30)]
    request = CandidateGenerationRequest(
        contract_version="1.0", video_id="v1", duration_ms=150000, generation_version="candidate-1",
        target_count_min=2, target_count_max=4, segments=segments,
    )
    candidates, _ = execute(request)
    assert len(candidates) == 4
    assert all(15000 <= c.duration_ms <= 60000 for c in candidates)
