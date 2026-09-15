"""Faster Whisper transcription adapter.

This module owns all provider, network, FFmpeg, and temporary-file details. The
rest of the service only sees the Transcriber port and validated domain values.
"""

from __future__ import annotations

import ipaddress
import os
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Protocol

from app.domain.errors import ServiceError
from app.domain.transcription import (
    TranscriptionConfig,
    TranscriptionResult,
    TranscriptionSegmentValue,
    TranscriptionWordValue,
    provider_error,
    seconds_to_ms,
    sentence_boundaries,
)


class MediaDownloader(Protocol):
    def download(self, media_url: str, destination: Path, *, max_bytes: int, timeout_seconds: float, chunk_size: int) -> None: ...


class AudioExtractor(Protocol):
    def extract(self, source: Path, destination: Path, *, timeout_seconds: float) -> None: ...


class ModelLoader(Protocol):
    def __call__(self, model_name: str, *, device: str, compute_type: str) -> Any: ...


def _is_public_hostname(hostname: str) -> bool:
    lowered = hostname.rstrip(".").lower()
    if lowered in {"localhost", "localhost.localdomain"}:
        return False
    try:
        address = ipaddress.ip_address(lowered)
    except ValueError:
        return True
    return not (address.is_private or address.is_loopback or address.is_link_local or address.is_reserved or address.is_unspecified)


class SignedMediaDownloader:
    """Bounded HTTPS downloader that does not follow insecure redirects."""

    def __init__(self, allowed_hosts: set[str] | None = None) -> None:
        configured = os.getenv("ML_MEDIA_ALLOWED_HOSTS", "") if allowed_hosts is None else ""
        self.allowed_hosts = {
            host.strip().rstrip(".").lower()
            for host in (configured.split(",") if allowed_hosts is None else allowed_hosts)
            if host.strip()
        }

    def _validate_url(self, media_url: str) -> None:
        parsed = urllib.parse.urlparse(media_url)
        hostname = parsed.hostname.rstrip(".").lower() if parsed.hostname else ""
        trusted_internal_host = hostname in self.allowed_hosts
        valid_scheme = parsed.scheme == "https" or (parsed.scheme == "http" and trusted_internal_host)
        if not valid_scheme or not hostname or parsed.username or parsed.password:
            raise provider_error(
                "INVALID_MEDIA_URL",
                "Media URL must use HTTPS, except for an explicitly allowed internal host.",
                retryable=False,
                status_code=400,
            )
        if not trusted_internal_host and not _is_public_hostname(hostname):
            raise provider_error("INVALID_MEDIA_URL", "Media URL host is not permitted.", retryable=False, status_code=400)

    def download(self, media_url: str, destination: Path, *, max_bytes: int, timeout_seconds: float, chunk_size: int) -> None:
        self._validate_url(media_url)

        request = urllib.request.Request(media_url, headers={"Accept": "video/*,audio/*"}, method="GET")
        deadline = time.monotonic() + timeout_seconds
        try:
            # A no-redirect opener prevents a signed HTTPS URL from silently
            # becoming an HTTP or untrusted host request.
            opener = urllib.request.build_opener(_NoRedirectHandler())
            with opener.open(request, timeout=timeout_seconds) as response:
                status = getattr(response, "status", response.getcode())
                if not 200 <= status < 300:
                    raise provider_error(
                        "MEDIA_DOWNLOAD_FAILED",
                        "Signed media URL returned an unsuccessful response.",
                        retryable=status >= 500 or status == 429,
                        details={"status": status},
                        status_code=502 if status >= 500 or status == 429 else 400,
                    )
                declared = response.headers.get("Content-Length")
                if declared:
                    try:
                        declared_bytes = int(declared)
                    except (TypeError, ValueError) as exc:
                        raise provider_error(
                            "MEDIA_DOWNLOAD_FAILED",
                            "Signed media returned an invalid size header.",
                            retryable=False,
                            status_code=502,
                        ) from exc
                    if declared_bytes < 0:
                        raise provider_error("MEDIA_DOWNLOAD_FAILED", "Signed media returned an invalid size header.", retryable=False, status_code=502)
                    if declared_bytes > max_bytes:
                        raise provider_error(
                            "MEDIA_TOO_LARGE",
                            "Signed media exceeds the configured download size limit.",
                            retryable=False,
                            details={"max_bytes": max_bytes},
                            status_code=413,
                        )
                total = 0
                with destination.open("wb") as output:
                    while True:
                        if time.monotonic() > deadline:
                            raise provider_error("MEDIA_DOWNLOAD_TIMEOUT", "Signed media download timed out.", retryable=True, status_code=504)
                        chunk = response.read(chunk_size)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > max_bytes:
                            raise provider_error(
                                "MEDIA_TOO_LARGE",
                                "Signed media exceeds the configured download size limit.",
                                retryable=False,
                                details={"max_bytes": max_bytes},
                                status_code=413,
                            )
                        output.write(chunk)
        except ServiceError:
            raise
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, socket.timeout, OSError) as exc:
            reason = getattr(exc, "reason", str(exc))
            raise provider_error(
                "MEDIA_DOWNLOAD_FAILED",
                "Unable to download signed media.",
                retryable=True,
                details={"reason": str(reason)[:200]},
                status_code=502,
            ) from exc


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise provider_error("MEDIA_REDIRECT_REJECTED", "Signed media redirects are not permitted.", retryable=False, status_code=400)


class FFmpegAudioExtractor:
    def extract(self, source: Path, destination: Path, *, timeout_seconds: float) -> None:
        command = [
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(source),
            "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", "-y", str(destination),
        ]
        try:
            completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout_seconds, check=False)
        except subprocess.TimeoutExpired as exc:
            raise provider_error("AUDIO_EXTRACTION_TIMEOUT", "FFmpeg audio extraction timed out.", retryable=True, status_code=504) from exc
        except OSError as exc:
            raise provider_error("AUDIO_EXTRACTION_UNAVAILABLE", "FFmpeg is unavailable in the ML service.", retryable=False, details={"reason": str(exc)[:200]}, status_code=500) from exc
        if completed.returncode != 0:
            raise provider_error(
                "AUDIO_EXTRACTION_FAILED",
                "FFmpeg could not extract audio from the media.",
                retryable=False,
                details={"stderr": (completed.stderr or "")[-500:]},
                status_code=422,
            )
        if not destination.exists() or destination.stat().st_size == 0:
            raise provider_error("AUDIO_EXTRACTION_FAILED", "FFmpeg did not produce an audio file.", retryable=False, status_code=422)


def _default_model_loader(model_name: str, *, device: str, compute_type: str) -> Any:
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise provider_error(
            "TRANSCRIPTION_PROVIDER_UNAVAILABLE",
            "The Faster Whisper provider is not installed in the ML service.",
            retryable=False,
            details={"provider": "faster-whisper"},
            status_code=500,
        ) from exc
    try:
        return WhisperModel(model_name, device=device, compute_type=compute_type)
    except Exception as exc:  # provider-specific exceptions vary by backend
        raise provider_error(
            "TRANSCRIPTION_MODEL_LOAD_FAILED",
            "Faster Whisper could not load the configured model.",
            retryable=True,
            details={"model": model_name, "device": device, "compute_type": compute_type},
            status_code=503,
        ) from exc


class FasterWhisperTranscriber:
    """Transcriber implementation with all external effects injectable."""

    def __init__(
        self,
        config: TranscriptionConfig | None = None,
        *,
        downloader: MediaDownloader | None = None,
        audio_extractor: AudioExtractor | None = None,
        model_loader: ModelLoader | None = None,
    ) -> None:
        try:
            self.config = config or TranscriptionConfig.from_env()
        except (TypeError, ValueError) as exc:
            raise provider_error(
                "TRANSCRIPTION_CONFIG_INVALID",
                "Transcription configuration is invalid.",
                retryable=False,
                status_code=500,
            ) from exc
        self.downloader = downloader or SignedMediaDownloader()
        self.audio_extractor = audio_extractor or FFmpegAudioExtractor()
        self.model_loader = model_loader or _default_model_loader
        self._model: Any | None = None

    def _get_model(self) -> Any:
        if self._model is None:
            self._model = self.model_loader(
                self.config.model_name,
                device=self.config.device,
                compute_type=self.config.compute_type,
            )
        return self._model

    def transcribe(self, media_url: str, duration_ms: int, language: str | None = None) -> TranscriptionResult:
        if duration_ms < 0 or duration_ms > self.config.max_duration_ms:
            raise ServiceError(
                "INVALID_DURATION",
                "Media duration exceeds the configured transcription limit.",
                retryable=False,
                details={"max_duration_ms": self.config.max_duration_ms},
                status_code=422,
            )
        with tempfile.TemporaryDirectory(prefix="cliprank-transcription-") as temporary:
            directory = Path(temporary)
            source = directory / "source.media"
            audio = directory / "audio.wav"
            self.downloader.download(
                media_url,
                source,
                max_bytes=self.config.max_media_bytes,
                timeout_seconds=self.config.download_timeout_seconds,
                chunk_size=self.config.chunk_size,
            )
            self.audio_extractor.extract(source, audio, timeout_seconds=self.config.ffmpeg_timeout_seconds)
            try:
                provider_segments, info = self._get_model().transcribe(
                    str(audio), language=language or None, word_timestamps=True,
                )
                result = self._convert(provider_segments, info, language=language, duration_ms=duration_ms)
            except ServiceError:
                raise
            except Exception as exc:
                raise provider_error("TRANSCRIPTION_FAILED", "Faster Whisper failed to transcribe the audio.", retryable=True, status_code=502) from exc
        return result

    def _convert(self, provider_segments: Any, info: Any, *, language: str | None, duration_ms: int) -> TranscriptionResult:
        converted: list[TranscriptionSegmentValue] = []
        previous_end = False
        previous_segment_end = -1
        try:
            iterable = list(provider_segments)
        except Exception as exc:
            raise provider_error("PROVIDER_INVALID_OUTPUT", "Faster Whisper returned an invalid segment stream.", retryable=False, status_code=502) from exc
        for sequence, segment in enumerate(iterable):
            text = str(getattr(segment, "text", "")).strip()
            start_ms = seconds_to_ms(getattr(segment, "start", None), field="segment.start")
            end_ms = seconds_to_ms(getattr(segment, "end", None), field="segment.end")
            if not text or end_ms <= start_ms:
                raise provider_error("PROVIDER_INVALID_OUTPUT", "Faster Whisper returned an invalid segment.", retryable=False, status_code=502)
            if duration_ms and end_ms > duration_ms:
                end_ms = duration_ms
            if end_ms <= start_ms:
                raise provider_error("PROVIDER_INVALID_OUTPUT", "Faster Whisper segment is outside media duration.", retryable=False, status_code=502)
            if start_ms < previous_segment_end:
                raise provider_error("PROVIDER_INVALID_OUTPUT", "Faster Whisper returned overlapping segments.", retryable=False, status_code=502)
            words: list[TranscriptionWordValue] = []
            for word in getattr(segment, "words", None) or ():
                word_text = str(getattr(word, "word", getattr(word, "text", ""))).strip()
                if not word_text or getattr(word, "start", None) is None or getattr(word, "end", None) is None:
                    continue
                word_start = seconds_to_ms(getattr(word, "start"), field="word.start")
                word_end = seconds_to_ms(getattr(word, "end"), field="word.end")
                if word_end <= word_start or word_start < start_ms or word_end > end_ms:
                    raise provider_error("PROVIDER_INVALID_OUTPUT", "Faster Whisper returned an out-of-bounds word timestamp.", retryable=False, status_code=502)
                words.append(TranscriptionWordValue(word_start, word_end, word_text))
            starts, ends = sentence_boundaries(text, previous_end, sequence == 0)
            converted.append(TranscriptionSegmentValue(sequence, start_ms, end_ms, text, tuple(words), starts, ends))
            previous_end = ends
            previous_segment_end = end_ms
        detected_language = getattr(info, "language", None) if info is not None else None
        result_language = language or (str(detected_language).strip() if detected_language else None)
        return TranscriptionResult(result_language, tuple(converted))
