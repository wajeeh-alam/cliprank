import pytest
from pydantic import ValidationError

from app.api.schemas import CandidateGenerationRequest
from app.domain.candidates import CandidatePolicy, _is_near_duplicate
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
    assert "NEAR_DUPLICATE_CANDIDATES_SUPPRESSED" in warnings
    assert len(candidates) == 2
    candidate = candidates[0]
    assert candidate.start_ms == 5000
    assert candidate.end_ms == 40000
    assert candidate.duration_ms == 35000


def test_audit_mode_accepts_three_to_sixty_second_source_and_does_not_force_five():
    request = CandidateGenerationRequest(
        contract_version="1.0", video_id="v1", duration_ms=26_000, generation_version="candidate-2",
        processing_mode="audit", min_duration_ms=3_000, max_duration_ms=60_000,
        target_count_min=1, target_count_max=5,
        segments=[
            {"sequence": 0, "start_ms": 0, "end_ms": 3_000, "text": "Setup."},
            {"sequence": 1, "start_ms": 3_000, "end_ms": 26_000, "text": "The complete point."},
        ],
    )
    candidates, warnings = execute(request)
    assert len(candidates) == 1
    assert candidates[0].duration_ms in {23_000, 26_000}
    assert "SOURCE_CANNOT_SUPPORT_TARGET_CANDIDATE_COUNT" not in warnings


def test_audit_mode_accepts_short_clip_but_returns_no_candidate_under_three_seconds():
    request = CandidateGenerationRequest(
        contract_version="1.0", video_id="v1", duration_ms=2_900, generation_version="candidate-2",
        processing_mode="audit", min_duration_ms=3_000, target_count_min=1, target_count_max=5,
        segments=[{"sequence": 0, "start_ms": 0, "end_ms": 2_900, "text": "Too short."}],
    )
    candidates, warnings = execute(request)
    assert candidates == []
    assert "SOURCE_CANNOT_SUPPORT_TARGET_CANDIDATE_COUNT" in warnings


def test_audit_mode_accepts_exactly_three_seconds():
    request = CandidateGenerationRequest(
        contract_version="1.0", video_id="v1", duration_ms=3_000, generation_version="candidate-2",
        processing_mode="audit", min_duration_ms=3_000, target_count_min=1, target_count_max=5,
        segments=[{"sequence": 0, "start_ms": 0, "end_ms": 3_000, "text": "Exact boundary."}],
    )
    candidates, _ = execute(request)
    assert [candidate.duration_ms for candidate in candidates] == [3_000]


def test_repurpose_mode_rejects_a_short_form_minimum():
    with pytest.raises(ValidationError, match="repurpose candidates must be at least 15 seconds"):
        CandidateGenerationRequest(
            contract_version="1.0", video_id="v1", duration_ms=30_000, generation_version="candidate-2",
            processing_mode="repurpose", min_duration_ms=3_000, target_count_min=1, target_count_max=5,
            segments=[{"sequence": 0, "start_ms": 0, "end_ms": 30_000, "text": "Invalid policy."}],
        )


def test_near_duplicate_family_keeps_deterministic_canonical_candidate():
    request = CandidateGenerationRequest(
        contract_version="1.0", video_id="v1", duration_ms=30_000, generation_version="candidate-2",
        processing_mode="audit", min_duration_ms=3_000, target_count_min=1, target_count_max=10,
        segments=[
            {"sequence": 0, "start_ms": 0, "end_ms": 3_000, "text": "Setup."},
            {"sequence": 1, "start_ms": 3_000, "end_ms": 26_000, "text": "The complete point."},
            {"sequence": 2, "start_ms": 26_000, "end_ms": 30_000, "text": "A distinct ending."},
        ],
    )
    candidates, warnings = execute(request)
    assert "NEAR_DUPLICATE_CANDIDATES_SUPPRESSED" in warnings
    boundaries = {(candidate.start_ms, candidate.end_ms) for candidate in candidates}
    assert len(boundaries) == len(candidates)
    assert (0, 30_000) in boundaries or (3_000, 30_000) in boundaries
    policy = CandidatePolicy(
        processing_mode="audit", min_duration_ms=3_000,
        target_count_min=1, target_count_max=10,
    )
    for index, candidate in enumerate(candidates):
        for other in candidates[index + 1 :]:
            assert not _is_near_duplicate(candidate.model_dump(), other.model_dump(), policy)


def test_partial_overlap_below_threshold_remains_distinct():
    request = CandidateGenerationRequest(
        contract_version="1.0", video_id="v1", duration_ms=100_000, generation_version="candidate-2",
        processing_mode="repurpose", min_duration_ms=15_000, max_duration_ms=20_000,
        target_count_min=1, target_count_max=10,
        segments=[
            {"sequence": 0, "start_ms": 0, "end_ms": 15_000, "text": "First idea."},
            {"sequence": 1, "start_ms": 15_000, "end_ms": 30_000, "text": "Second idea."},
            {"sequence": 2, "start_ms": 30_000, "end_ms": 45_000, "text": "Third idea."},
        ],
    )
    candidates, _ = execute(request)
    assert len(candidates) == 3


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
