from app.domain.candidates import CandidatePolicy, TranscriptSegmentValue, generate_candidates
from app.domain.errors import UnsupportedOperation
from app.domain.ranking import score_candidate, validate_weights


class UnsupportedTranscriber:
    def transcribe(self, media_url: str, duration_ms: int) -> object:
        raise UnsupportedOperation("transcription")


class UnsupportedSemanticFeatureExtractor:
    def extract(self, transcript: str) -> object:
        raise UnsupportedOperation("semantic feature extraction")


class UnsupportedAudioFeatureExtractor:
    def extract(self, media_url: str, start_ms: int, end_ms: int) -> object:
        raise UnsupportedOperation("audio feature extraction")


class UnsupportedVisualFeatureExtractor:
    def extract(self, media_url: str, start_ms: int, end_ms: int) -> object:
        raise UnsupportedOperation("visual feature extraction")


class DeterministicCandidateGenerator:
    def generate(self, segments: list[TranscriptSegmentValue], duration_ms: int, policy: CandidatePolicy) -> tuple[list[dict], list[str]]:
        return generate_candidates(segments, duration_ms, policy)


class HeuristicRanker:
    def rank(self, candidates: list[dict], weights: dict[str, float]) -> list[dict]:
        validate_weights(weights)
        if not isinstance(candidates, list) or not candidates or len(candidates) > 40:
            raise ValueError("candidates must contain between 1 and 40 items")
        if any(not isinstance(candidate, dict) or "features" not in candidate for candidate in candidates):
            raise ValueError("every candidate must contain features")
        candidate_ids = [candidate.get("candidate_id") for candidate in candidates]
        if any(not isinstance(candidate_id, str) or not candidate_id for candidate_id in candidate_ids):
            raise ValueError("every candidate must have a non-empty candidate_id")
        if len(candidate_ids) != len(set(candidate_ids)):
            raise ValueError("candidate ids must be unique")
        scored = []
        for candidate in candidates:
            result = score_candidate(candidate["features"], weights)
            scored.append({"candidate_id": candidate["candidate_id"], **result})
        scored.sort(key=lambda item: (-item["clip_score"], item["candidate_id"]))
        return [{**item, "rank": index} for index, item in enumerate(scored, start=1)]
