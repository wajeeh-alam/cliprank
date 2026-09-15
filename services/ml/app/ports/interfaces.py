from typing import Protocol

from app.domain.candidates import CandidatePolicy, TranscriptSegmentValue
from app.domain.errors import ServiceError


class Transcriber(Protocol):
    def transcribe(self, media_url: str, duration_ms: int) -> object: ...


class SemanticFeatureExtractor(Protocol):
    def extract(self, transcript: str) -> object: ...


class AudioFeatureExtractor(Protocol):
    def extract(self, media_url: str, start_ms: int, end_ms: int) -> object: ...


class VisualFeatureExtractor(Protocol):
    def extract(self, media_url: str, start_ms: int, end_ms: int) -> object: ...


class CandidateGenerator(Protocol):
    def generate(self, segments: list[TranscriptSegmentValue], duration_ms: int, policy: CandidatePolicy) -> tuple[list[dict], list[str]]: ...


class ClipRanker(Protocol):
    def rank(self, candidates: list[dict], weights: dict[str, float]) -> list[dict]: ...
