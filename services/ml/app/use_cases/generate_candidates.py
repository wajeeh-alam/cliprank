from app.adapters.baseline import DeterministicCandidateGenerator
from app.api.schemas import Candidate, CandidateGenerationRequest
from app.domain.candidates import CandidatePolicy, TranscriptSegmentValue


def execute(request: CandidateGenerationRequest, generator=None) -> tuple[list[Candidate], list[str]]:
    generator = generator or DeterministicCandidateGenerator()
    values = [
        TranscriptSegmentValue(
            sequence=s.sequence,
            start_ms=s.start_ms,
            end_ms=s.end_ms,
            text=s.text,
            is_sentence_boundary_start=s.is_sentence_boundary_start,
            is_sentence_boundary_end=s.is_sentence_boundary_end,
        )
        for s in request.segments
    ]
    raw, warnings = generator.generate(
        values,
        request.duration_ms,
        CandidatePolicy(
            min_duration_ms=request.min_duration_ms,
            max_duration_ms=request.max_duration_ms,
            target_count_min=request.target_count_min,
            target_count_max=request.target_count_max,
            processing_mode=request.processing_mode,
        ),
    )
    return [Candidate.model_validate(item) for item in raw], warnings
