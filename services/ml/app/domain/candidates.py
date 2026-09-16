from dataclasses import dataclass
from typing import Literal

from app.domain.errors import ServiceError


@dataclass(frozen=True)
class CandidatePolicy:
    min_duration_ms: int = 15_000
    max_duration_ms: int = 60_000
    target_count_min: int = 10
    target_count_max: int = 40
    processing_mode: Literal["audit", "repurpose"] = "repurpose"
    duplicate_iou_threshold: float = 0.80
    duplicate_containment_threshold: float = 0.92
    duplicate_boundary_delta_ms: int = 3_000


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
    """Build distinct, whole-segment windows with deterministic boundaries.

    A window starts at each transcript segment and ends at the furthest usable
    sentence boundary (falling back to the furthest valid segment). Short-form
    audit mode allows 3–60 second sources and intentionally returns fewer than
    five results when the source contains only one distinct edit. Long-form
    repurposing retains the original 15–60 second policy.

    Near-identical windows are hard-suppressed before the count cap is applied.
    The canonical window is selected by boundary quality, then shorter duration,
    then stable source order. This makes output reproducible without using model
    scores that do not exist at candidate-generation time.
    """
    if policy.processing_mode not in {"audit", "repurpose"}:
        raise ServiceError("INVALID_POLICY", "Candidate processing mode is invalid.")
    minimum_allowed = 3_000 if policy.processing_mode == "audit" else 15_000
    if policy.min_duration_ms < minimum_allowed or policy.max_duration_ms < policy.min_duration_ms:
        raise ServiceError("INVALID_POLICY", "Candidate duration policy is invalid.")
    if policy.target_count_min < 1 or policy.target_count_max < policy.target_count_min:
        raise ServiceError("INVALID_POLICY", "Candidate count policy is invalid.")
    if not 0.0 < policy.duplicate_iou_threshold <= 1.0:
        raise ServiceError("INVALID_POLICY", "Duplicate IoU threshold is invalid.")
    if not 0.0 < policy.duplicate_containment_threshold <= 1.0:
        raise ServiceError("INVALID_POLICY", "Duplicate containment threshold is invalid.")
    if policy.duplicate_boundary_delta_ms < 0:
        raise ServiceError("INVALID_POLICY", "Duplicate boundary delta must be non-negative.")
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

    raw_candidates: list[dict] = []
    for start_index, start in enumerate(ordered):
        valid_end_indices: list[int] = []
        for end_index in range(start_index, len(ordered)):
            end = ordered[end_index]
            length = end.end_ms - start.start_ms
            if length > policy.max_duration_ms:
                break
            if length >= policy.min_duration_ms:
                valid_end_indices.append(end_index)
        if not valid_end_indices:
            continue

        # Prefer a terminal sentence boundary when one is available, while
        # preserving the previous furthest-end behavior as a deterministic
        # fallback for transcripts without punctuation flags.
        boundary_end_indices = [index for index in valid_end_indices if ordered[index].is_sentence_boundary_end]
        last_valid_index = (boundary_end_indices or valid_end_indices)[-1]
        end = ordered[last_valid_index]
        raw_candidates.append(
            {
                "start_ms": start.start_ms,
                "end_ms": end.end_ms,
                "duration_ms": end.end_ms - start.start_ms,
                "transcript": " ".join(x.text.strip() for x in ordered[start_index : last_valid_index + 1]).strip(),
                "source_segment_sequences": [x.sequence for x in ordered[start_index : last_valid_index + 1]],
                # Internal only: this is removed before returning the contract.
                # Starts/ends aligned to sentence boundaries are preferred when
                # two otherwise similar windows compete for the same family.
                "_boundary_score": int(start.is_sentence_boundary_start) + int(end.is_sentence_boundary_end),
            }
        )

    candidates, suppressed_count = _suppress_near_duplicates(raw_candidates, policy)

    # Keep at most the configured maximum while preserving source order and spread.
    if len(candidates) > policy.target_count_max:
        if policy.target_count_max == 1:
            indices = [0]
        else:
            indices = [round(i * (len(candidates) - 1) / (policy.target_count_max - 1)) for i in range(policy.target_count_max)]
        candidates = [candidates[i] for i in indices]
    warnings: list[str] = []
    if suppressed_count:
        warnings.append("NEAR_DUPLICATE_CANDIDATES_SUPPRESSED")
    if len(candidates) < policy.target_count_min:
        warnings.append("SOURCE_CANNOT_SUPPORT_TARGET_CANDIDATE_COUNT")
    return [
        {"sequence": i, **{key: value for key, value in candidate.items() if not key.startswith("_")}}
        for i, candidate in enumerate(candidates)
    ], warnings


def _suppress_near_duplicates(candidates: list[dict], policy: CandidatePolicy) -> tuple[list[dict], int]:
    """Keep one canonical candidate from every near-duplicate family.

    Selection is greedy over a total ordering, so the result does not depend on
    transcript input order. A candidate is suppressed when it overlaps an
    already-kept candidate by at least the configured IoU, or when it nearly
    contains/is contained by that candidate and both boundaries are within the
    configured tolerance.
    """

    def canonical_key(candidate: dict) -> tuple[int, int, int, int]:
        return (
            -candidate["_boundary_score"],
            candidate["duration_ms"],
            candidate["start_ms"],
            candidate["end_ms"],
        )

    kept: list[dict] = []
    suppressed = 0
    for candidate in sorted(candidates, key=canonical_key):
        if any(_is_near_duplicate(candidate, existing, policy) for existing in kept):
            suppressed += 1
            continue
        kept.append(candidate)

    # The persisted sequence is source order, not canonical-selection order.
    kept.sort(key=lambda candidate: (candidate["start_ms"], candidate["end_ms"], canonical_key(candidate)))
    return kept, suppressed


def _is_near_duplicate(first: dict, second: dict, policy: CandidatePolicy) -> bool:
    overlap_ms = max(0, min(first["end_ms"], second["end_ms"]) - max(first["start_ms"], second["start_ms"]))
    if overlap_ms <= 0:
        return False
    union_ms = max(first["end_ms"], second["end_ms"]) - min(first["start_ms"], second["start_ms"])
    iou = overlap_ms / union_ms
    if iou >= policy.duplicate_iou_threshold:
        return True

    shorter_duration = min(first["duration_ms"], second["duration_ms"])
    containment = overlap_ms / shorter_duration
    boundary_delta = max(
        abs(first["start_ms"] - second["start_ms"]),
        abs(first["end_ms"] - second["end_ms"]),
    )
    return containment >= policy.duplicate_containment_threshold and boundary_delta <= policy.duplicate_boundary_delta_ms
