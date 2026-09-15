"""Domain values and deterministic helpers for timestamped transcription."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Any

from app.domain.errors import ServiceError


@dataclass(frozen=True)
class TranscriptionConfig:
    """Runtime limits and Faster Whisper settings.

    The model is deliberately not loaded by configuration construction. This keeps
    service startup cheap and makes model loading lazy and replaceable in tests.
    """

    model_name: str = "small"
    device: str = "cpu"
    compute_type: str = "int8"
    max_media_bytes: int = 2 * 1024 * 1024 * 1024
    download_timeout_seconds: float = 120.0
    ffmpeg_timeout_seconds: float = 120.0
    max_duration_ms: int = 60 * 60 * 1000
    chunk_size: int = 1024 * 1024

    def __post_init__(self) -> None:
        if not self.model_name.strip():
            raise ValueError("model_name must not be empty")
        if not self.device.strip() or not self.compute_type.strip():
            raise ValueError("device and compute_type must not be empty")
        if self.max_media_bytes <= 0 or self.download_timeout_seconds <= 0:
            raise ValueError("media size and download timeout must be positive")
        if self.ffmpeg_timeout_seconds <= 0 or self.max_duration_ms <= 0:
            raise ValueError("ffmpeg timeout and maximum duration must be positive")
        if self.chunk_size <= 0:
            raise ValueError("chunk_size must be positive")

    @classmethod
    def from_env(cls) -> "TranscriptionConfig":
        """Read deployment configuration without importing Faster Whisper."""

        import os

        def text(name: str, fallback: str) -> str:
            return os.getenv(name, os.getenv(name.replace("ML_TRANSCRIPTION_", "WHISPER_"), fallback))

        def integer(name: str, fallback: int) -> int:
            return int(os.getenv(name, str(fallback)))

        def number(name: str, fallback: float) -> float:
            return float(os.getenv(name, str(fallback)))

        return cls(
            model_name=text("ML_TRANSCRIPTION_MODEL", cls.model_name),
            device=text("ML_TRANSCRIPTION_DEVICE", cls.device),
            compute_type=text("ML_TRANSCRIPTION_COMPUTE_TYPE", cls.compute_type),
            max_media_bytes=integer("ML_TRANSCRIPTION_MAX_MEDIA_BYTES", cls.max_media_bytes),
            download_timeout_seconds=number("ML_TRANSCRIPTION_DOWNLOAD_TIMEOUT_SECONDS", cls.download_timeout_seconds),
            ffmpeg_timeout_seconds=number("ML_TRANSCRIPTION_FFMPEG_TIMEOUT_SECONDS", cls.ffmpeg_timeout_seconds),
            max_duration_ms=integer("ML_TRANSCRIPTION_MAX_DURATION_MS", cls.max_duration_ms),
        )


@dataclass(frozen=True)
class TranscriptionWordValue:
    start_ms: int
    end_ms: int
    text: str


@dataclass(frozen=True)
class TranscriptionSegmentValue:
    sequence: int
    start_ms: int
    end_ms: int
    text: str
    words: tuple[TranscriptionWordValue, ...] = ()
    is_sentence_boundary_start: bool = False
    is_sentence_boundary_end: bool = False


@dataclass(frozen=True)
class TranscriptionResult:
    language: str | None
    segments: tuple[TranscriptionSegmentValue, ...]


_SENTENCE_END = re.compile(r"[.!?…]\s*$")


def seconds_to_ms(value: Any, *, field: str) -> int:
    """Convert provider seconds to a non-negative integer millisecond value."""

    try:
        seconds = float(value)
    except (TypeError, ValueError) as exc:
        raise ServiceError(
            "PROVIDER_INVALID_OUTPUT",
            f"Faster Whisper returned an invalid {field} timestamp.",
            details={"field": field},
            status_code=502,
        ) from exc
    if not math.isfinite(seconds) or seconds < 0:
        raise ServiceError(
            "PROVIDER_INVALID_OUTPUT",
            f"Faster Whisper returned an invalid {field} timestamp.",
            details={"field": field, "value": repr(value)},
            status_code=502,
        )
    return int(round(seconds * 1000))


def sentence_boundaries(text: str, previous_end: bool, is_first: bool) -> tuple[bool, bool]:
    """Mark boundaries using only transcript text and segment order.

    Faster Whisper's segment boundaries are timing hints, not sentence parsing.
    A segment starts a sentence when it is first or follows terminal punctuation;
    it ends one when its text ends in deterministic terminal punctuation.
    """

    starts = is_first or previous_end
    ends = bool(_SENTENCE_END.search(text.strip()))
    return starts, ends


def provider_error(code: str, message: str, *, retryable: bool, details: dict[str, Any] | None = None, status_code: int = 502) -> ServiceError:
    return ServiceError(code, message, retryable=retryable, details=details or {}, status_code=status_code)
