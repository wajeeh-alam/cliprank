from dataclasses import dataclass

from app.domain.errors import ServiceError


@dataclass(frozen=True)
class CandidatePolicy:
    min_duration_ms: int = 15_000
    max_duration_ms: int = 60_000
    target_count_min: int = 10
    target_count_max: int = 40


@dataclass(frozen=True)
class TranscriptSegmentValue:
    sequence: int
    start_ms: int
    end_ms: int
    text: str
    is_sentence_boundary_start: bool = False
    is_sentence_boundary_end: bool = False


def generate_candidates(
    segments: list[TranscriptSegmentValue], duration_ms: int, policy: CandidatePolicy
) -> tuple[list[dict], list[str]]:
    """Build complete, whole-segment windows with deterministic boundaries.

    A window starts at each segment and ends at the furthest segment that keeps it
    within the policy. Windows are then deterministically thinned to the requested
    maximum. No candidate is padded or clipped into an invalid interval.
    """
    if policy.min_duration_ms <= 0 or policy.max_duration_ms < policy.min_duration_ms:
        raise ServiceError("INVALID_POLICY", "Candidate duration policy is invalid.")
    if policy.target_count_min < 1 or policy.target_count_max < policy.target_count_min:
        raise ServiceError("INVALID_POLICY", "Candidate count policy is invalid.")
    if duration_ms < 0:
        raise ServiceError("INVALID_DURATION", "duration_ms must be non-negative.")
    ordered = sorted(segments, key=lambda item: (item.start_ms, item.sequence))
    previous_end = 0
    for item in ordered:
        if not 0 <= item.start_ms < item.end_ms <= duration_ms:
            raise ServiceError("INVALID_TIMESTAMP", "Transcript segment bounds are invalid.")
        if item.start_ms < previous_end:
            raise ServiceError("INVALID_TIMESTAMP", "Transcript segments overlap.")
        previous_end = item.end_ms

    candidates: list[dict] = []
    for start_index, start in enumerate(ordered):
        last_valid_index = None
        for end_index in range(start_index, len(ordered)):
            end = ordered[end_index]
            length = end.end_ms - start.start_ms
            if length > policy.max_duration_ms:
                break
            if length >= policy.min_duration_ms:
                last_valid_index = end_index
        if last_valid_index is None:
            continue
        end = ordered[last_valid_index]
        candidates.append(
            {
                "start_ms": start.start_ms,
                "end_ms": end.end_ms,
                "duration_ms": end.end_ms - start.start_ms,
                "transcript": " ".join(x.text.strip() for x in ordered[start_index : last_valid_index + 1]).strip(),
                "source_segment_sequences": [x.sequence for x in ordered[start_index : last_valid_index + 1]],
            }
        )

    # Keep at most the configured maximum while preserving source order and spread.
    if len(candidates) > policy.target_count_max:
        if policy.target_count_max == 1:
            indices = [0]
        else:
            indices = [round(i * (len(candidates) - 1) / (policy.target_count_max - 1)) for i in range(policy.target_count_max)]
        candidates = [candidates[i] for i in indices]
    warnings: list[str] = []
    if len(candidates) < policy.target_count_min:
        warnings.append("SOURCE_CANNOT_SUPPORT_TARGET_CANDIDATE_COUNT")
    return [{"sequence": i, **candidate} for i, candidate in enumerate(candidates)], warnings
