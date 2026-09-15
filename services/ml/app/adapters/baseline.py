from app.domain.candidates import CandidatePolicy, TranscriptSegmentValue, generate_candidates
from app.domain.errors import UnsupportedOperation
from app.domain.ranking import score_candidate


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
        scored = []
        for candidate in candidates:
            result = score_candidate(candidate["features"], weights)
            scored.append({"candidate_id": candidate["candidate_id"], **result})
        scored.sort(key=lambda item: (-item["clip_score"], item["candidate_id"]))
        return [{**item, "rank": index} for index, item in enumerate(scored, start=1)]
