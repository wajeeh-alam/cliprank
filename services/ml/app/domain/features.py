"""Configuration and measured values for deterministic feature extraction."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FeatureExtractionConfig:
    model_version: str = "deterministic-features-1"
    max_media_bytes: int = 2 * 1024 * 1024 * 1024
    download_timeout_seconds: float = 120.0
    ffmpeg_timeout_seconds: float = 120.0
    ffprobe_timeout_seconds: float = 20.0
    max_candidate_duration_ms: int = 60 * 1000
    visual_sample_count: int = 12
    audio_window_ms: int = 100

    def __post_init__(self) -> None:
        if not self.model_version.strip():
            raise ValueError("model_version must not be empty")
        if self.max_media_bytes <= 0:
            raise ValueError("max_media_bytes must be positive")
        if self.download_timeout_seconds <= 0 or self.ffmpeg_timeout_seconds <= 0 or self.ffprobe_timeout_seconds <= 0:
            raise ValueError("feature extraction timeouts must be positive")
        if self.max_candidate_duration_ms <= 0 or self.visual_sample_count <= 0 or self.audio_window_ms <= 0:
            raise ValueError("feature extraction limits must be positive")

    @classmethod
    def from_env(cls) -> "FeatureExtractionConfig":
        import os

        def integer(name: str, fallback: int) -> int:
            return int(os.getenv(name, str(fallback)))

        def number(name: str, fallback: float) -> float:
            return float(os.getenv(name, str(fallback)))

        return cls(
            model_version=os.getenv("ML_FEATURE_MODEL_VERSION", cls.model_version),
            max_media_bytes=integer("ML_FEATURE_MAX_MEDIA_BYTES", cls.max_media_bytes),
            download_timeout_seconds=number("ML_FEATURE_DOWNLOAD_TIMEOUT_SECONDS", cls.download_timeout_seconds),
            ffmpeg_timeout_seconds=number("ML_FEATURE_FFMPEG_TIMEOUT_SECONDS", cls.ffmpeg_timeout_seconds),
            ffprobe_timeout_seconds=number("ML_FEATURE_FFPROBE_TIMEOUT_SECONDS", cls.ffprobe_timeout_seconds),
            max_candidate_duration_ms=integer("ML_FEATURE_MAX_CANDIDATE_DURATION_MS", cls.max_candidate_duration_ms),
            visual_sample_count=integer("ML_FEATURE_VISUAL_SAMPLE_COUNT", cls.visual_sample_count),
            audio_window_ms=integer("ML_FEATURE_AUDIO_WINDOW_MS", cls.audio_window_ms),
        )
