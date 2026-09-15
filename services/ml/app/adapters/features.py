"""Truthful, deterministic media feature extraction.

The adapter deliberately uses only measured transcript/audio/video signals. It
does not call an LLM and does not fill unavailable visual measurements with
random or model-shaped guesses; unavailable optional capabilities are returned
as explicit warnings alongside bounded zero measurements.
"""

from __future__ import annotations

import json
import math
import re
import struct
import subprocess
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Protocol

from app.adapters.faster_whisper import MediaDownloader, SignedMediaDownloader
from app.api.schemas import (
    AudioFeatures,
    ContentTypeValue,
    FeatureRequest,
    FeatureSet,
    SemanticFeatures,
    StructuralFeatures,
    VisualFeatures,
)
from app.domain.enums import ContentType, HookType
from app.domain.errors import ServiceError
from app.domain.features import FeatureExtractionConfig


class MediaProbe(Protocol):
    def probe(self, source: Path, *, timeout_seconds: float) -> "ProbeResult": ...


class SegmentAudioExtractor(Protocol):
    def extract(self, source: Path, destination: Path, *, start_ms: int, end_ms: int, timeout_seconds: float) -> None: ...


class VisualAnalyzer(Protocol):
    def analyze(self, source: Path, *, start_ms: int, end_ms: int, sample_count: int) -> "VisualMeasurement": ...


@dataclass(frozen=True)
class ProbeResult:
    has_audio: bool
    has_video: bool
    duration_ms: int | None = None


@dataclass(frozen=True)
class VisualMeasurement:
    face_presence_ratio: float = 0.0
    visual_motion: float = 0.0
    scene_change_rate: float = 0.0
    screen_recording_ratio: float = 0.0
    camera_change_frequency: float = 0.0
    sample_count: int = 0
    warnings: tuple[str, ...] = ()


def _bounded(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


class FFprobeMediaProbe:
    def probe(self, source: Path, *, timeout_seconds: float) -> ProbeResult:
        command = [
            "ffprobe", "-v", "error", "-show_streams", "-show_format",
            "-print_format", "json", str(source),
        ]
        try:
            completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout_seconds, check=False)
        except subprocess.TimeoutExpired as exc:
            raise ServiceError("MEDIA_PROBE_TIMEOUT", "ffprobe timed out while inspecting media.", retryable=True, status_code=504) from exc
        except OSError as exc:
            raise ServiceError("MEDIA_PROBE_UNAVAILABLE", "ffprobe is unavailable in the ML service.", retryable=False, details={"reason": str(exc)[:200]}, status_code=500) from exc
        if completed.returncode != 0:
            raise ServiceError(
                "MEDIA_PROBE_FAILED",
                "ffprobe could not inspect the media.",
                retryable=False,
                details={"stderr": (completed.stderr or "")[-500:]},
                status_code=422,
            )
        try:
            payload = json.loads(completed.stdout or "{}")
            streams = payload.get("streams", [])
            has_audio = any(stream.get("codec_type") == "audio" for stream in streams)
            has_video = any(stream.get("codec_type") == "video" for stream in streams)
            duration = payload.get("format", {}).get("duration")
            duration_ms = int(round(float(duration) * 1000)) if duration is not None else None
        except (AttributeError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ServiceError("MEDIA_PROBE_INVALID_OUTPUT", "ffprobe returned invalid media metadata.", retryable=False, status_code=502) from exc
        return ProbeResult(has_audio=has_audio, has_video=has_video, duration_ms=duration_ms)


class FFmpegSegmentAudioExtractor:
    def extract(self, source: Path, destination: Path, *, start_ms: int, end_ms: int, timeout_seconds: float) -> None:
        duration_ms = end_ms - start_ms
        command = [
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-ss", f"{start_ms / 1000:.3f}", "-i", str(source),
            "-t", f"{duration_ms / 1000:.3f}", "-vn", "-ac", "1", "-ar", "16000",
            "-f", "wav", "-y", str(destination),
        ]
        try:
            completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout_seconds, check=False)
        except subprocess.TimeoutExpired as exc:
            raise ServiceError("AUDIO_EXTRACTION_TIMEOUT", "FFmpeg audio extraction timed out.", retryable=True, status_code=504) from exc
        except OSError as exc:
            raise ServiceError("AUDIO_EXTRACTION_UNAVAILABLE", "FFmpeg is unavailable in the ML service.", retryable=False, details={"reason": str(exc)[:200]}, status_code=500) from exc
        if completed.returncode != 0:
            raise ServiceError(
                "AUDIO_EXTRACTION_FAILED",
                "FFmpeg could not extract candidate audio.",
                retryable=False,
                details={"stderr": (completed.stderr or "")[-500:]},
                status_code=422,
            )
        if not destination.exists() or destination.stat().st_size == 0:
            raise ServiceError("AUDIO_EXTRACTION_FAILED", "FFmpeg did not produce candidate audio.", retryable=False, status_code=422)


class OptionalOpenCVVisualAnalyzer:
    """Use OpenCV when installed; otherwise report optional limitations."""

    def analyze(self, source: Path, *, start_ms: int, end_ms: int, sample_count: int) -> VisualMeasurement:
        try:
            import cv2
        except ImportError:
            return VisualMeasurement(warnings=("VISUAL_FRAME_ANALYSIS_UNAVAILABLE", "VISUAL_FACE_DETECTION_UNAVAILABLE", "VISUAL_SCREEN_RECORDING_CLASSIFICATION_UNAVAILABLE"))
        capture = cv2.VideoCapture(str(source))
        if not capture.isOpened():
            return VisualMeasurement(warnings=("VISUAL_FRAME_ANALYSIS_UNAVAILABLE", "VISUAL_FACE_DETECTION_UNAVAILABLE", "VISUAL_SCREEN_RECORDING_CLASSIFICATION_UNAVAILABLE"))
        try:
            duration_ms = max(1, end_ms - start_ms)
            frames: list[Any] = []
            face_detector = None
            face_warning = False
            try:
                cascade_path = Path(cv2.data.haarcascades) / "haarcascade_frontalface_default.xml"
                face_detector = cv2.CascadeClassifier(str(cascade_path))
                if face_detector.empty():
                    face_detector = None
                    face_warning = True
            except (AttributeError, OSError):
                face_warning = True
            face_hits = 0
            for index in range(sample_count):
                timestamp = start_ms + int(duration_ms * index / max(1, sample_count - 1))
                capture.set(cv2.CAP_PROP_POS_MSEC, timestamp)
                ok, frame = capture.read()
                if ok and frame is not None:
                    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                    frames.append(gray)
                    if face_detector is not None:
                        detected = face_detector.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=4)
                        if len(detected) > 0:
                            face_hits += 1
            warnings = ["VISUAL_SCREEN_RECORDING_CLASSIFICATION_UNAVAILABLE"]
            if face_warning:
                warnings.append("VISUAL_FACE_DETECTION_UNAVAILABLE")
            if len(frames) < 2:
                return VisualMeasurement(face_presence_ratio=_bounded(face_hits / max(1, len(frames))), sample_count=len(frames), warnings=tuple(warnings))
            differences = [float(cv2.absdiff(previous, current).mean()) / 255.0 for previous, current in zip(frames, frames[1:])]
            scene_changes = sum(1 for difference in differences if difference >= 0.20)
            return VisualMeasurement(
                face_presence_ratio=_bounded(face_hits / len(frames)),
                visual_motion=_bounded(sum(differences) / len(differences)),
                scene_change_rate=_bounded(scene_changes / len(differences)),
                camera_change_frequency=_bounded(scene_changes / max(1.0, duration_ms / 1000.0)),
                sample_count=len(frames),
                warnings=tuple(warnings),
            )
        finally:
            capture.release()


_WORD_RE = re.compile(r"[\w']+", re.UNICODE)
_STOP_WORDS = {
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "i", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "we", "what", "when", "with", "you",
}
_EMOTION_WORDS = {"love", "hate", "fear", "excited", "amazing", "terrible", "happy", "sad", "angry", "surprise", "surprising", "win", "fail", "failure", "success", "urgent"}
_TECHNICAL_WORDS = {"api", "code", "coding", "database", "debug", "deploy", "docker", "function", "http", "javascript", "model", "python", "query", "schema", "sql", "system", "technical", "algorithm"}
_CTA_WORDS = {"follow", "subscribe", "comment", "share", "save", "join", "try", "learn", "download", "click"}
_TOPIC_WORDS = {
    "coding_tip": _TECHNICAL_WORDS | {"programming", "software"},
    "career_advice": {"career", "interview", "job", "resume", "work", "salary", "manager"},
    "educational": {"learn", "explain", "lesson", "teach", "education", "why", "because"},
    "project_demo": {"demo", "build", "built", "project", "launch", "product"},
    "opinion": {"opinion", "think", "believe", "should", "wrong", "right"},
}


def _words(text: str) -> list[str]:
    return [match.group(0).lower() for match in _WORD_RE.finditer(text)]


def _semantic_features(request: FeatureRequest) -> SemanticFeatures:
    words = _words(request.transcript)
    unique_words = set(words)
    first_text = request.transcript_segments[0].text.strip()
    first_lower = first_text.lower()
    first_words = _words(first_text)
    word_count = len(words)
    non_stop = [word for word in words if word not in _STOP_WORDS]
    question = "?" in first_text or first_lower.startswith(("how ", "why ", "what ", "who ", "when "))
    contrarian = first_lower.startswith(("unpopular opinion", "most people", "stop ", "everyone is wrong"))
    surprising = any(token in first_lower for token in ("actually", "secret", "nobody", "never", "surprising"))
    personal = any(token in first_words for token in ("i", "my", "we", "our"))
    result_first = bool(first_words and (first_words[0].isdigit() or first_words[0] in {"result", "here", "this"}))
    problem = any(token in first_lower for token in ("problem", "struggle", "mistake", "issue"))
    if question:
        hook_type = HookType.QUESTION
    elif contrarian:
        hook_type = HookType.CONTRARIAN
    elif surprising:
        hook_type = HookType.SURPRISING_CLAIM
    elif personal:
        hook_type = HookType.PERSONAL_STORY
    elif result_first:
        hook_type = HookType.RESULT_FIRST
    elif problem:
        hook_type = HookType.PROBLEM
    elif word_count >= 3:
        hook_type = HookType.CURIOSITY_GAP
    else:
        hook_type = HookType.NONE
    sentence_count = max(1, len(re.findall(r"[.!?]+", request.transcript)))
    punctuation = len(re.findall(r"[.!?]", first_text))
    lexical_hook = (0.45 if question else 0.0) + (0.25 if surprising or contrarian else 0.0) + min(len(first_words) / 30.0, 0.2)
    topic_scores = {topic: len(unique_words & vocabulary) for topic, vocabulary in _TOPIC_WORDS.items()}
    topic_key = max(topic_scores, key=topic_scores.get) if topic_scores and max(topic_scores.values()) else "other"
    content_type = {
        "coding_tip": ContentType.CODING_TIP,
        "career_advice": ContentType.CAREER_ADVICE,
        "educational": ContentType.EDUCATIONAL,
        "project_demo": ContentType.PROJECT_DEMO,
        "opinion": ContentType.OPINION,
    }.get(topic_key, ContentType.OTHER)
    boundary_ends = sum(1 for segment in request.transcript_segments if segment.is_sentence_boundary_end)
    payoff_terms = {"therefore", "finally", "result", "so", "that's why", "conclusion"}
    payoff = sum(1 for term in payoff_terms if term in request.transcript.lower())
    return SemanticFeatures(
        hook_strength=_bounded(lexical_hook),
        standalone_clarity=_bounded((0.35 if first_words else 0.0) + (0.35 if punctuation or boundary_ends else 0.0) + (0.3 if len(unique_words) >= 5 else len(unique_words) / 16)),
        information_density=_bounded(len(unique_words) / max(1, word_count)),
        novelty=_bounded(len(set(non_stop)) / max(1, len(non_stop))),
        emotional_intensity=_bounded(sum(1 for word in words if word in _EMOTION_WORDS) / max(1, word_count) * 4),
        quotability=_bounded((0.5 if 5 <= word_count <= 30 else 0.2) + (0.3 if '"' in request.transcript else 0.0) + (0.2 if sentence_count >= 1 else 0.0)),
        payoff_strength=_bounded(payoff / 3.0 + (0.35 if request.transcript_segments[-1].is_sentence_boundary_end else 0.0)),
        story_completeness=_bounded((boundary_ends / max(1, len(request.transcript_segments))) * 0.6 + (0.4 if sentence_count >= 2 else 0.2)),
        technical_depth=_bounded(sum(1 for word in words if word in _TECHNICAL_WORDS) / max(1, word_count) * 3),
        call_to_action_presence=_bounded(sum(1 for word in words if word in _CTA_WORDS) / max(1, word_count) * 5),
        topic=topic_key,
        content_type=content_type,
        hook_type=hook_type,
    )


@dataclass(frozen=True)
class AudioMeasurement:
    average_energy: float
    energy_variance: float
    energy_change_at_hook: float
    silence_ratio: float
    longest_pause_ms: int
    pause_frequency: float
    dead_air_start_ms: int
    dead_air_end_ms: int


def _read_pcm_wav(path: Path, window_ms: int) -> tuple[AudioMeasurement, int]:
    try:
        with wave.open(str(path), "rb") as stream:
            channels = stream.getnchannels()
            sample_width = stream.getsampwidth()
            sample_rate = stream.getframerate()
            frame_count = stream.getnframes()
            raw = stream.readframes(frame_count)
    except (OSError, wave.Error) as exc:
        raise ServiceError("AUDIO_READ_FAILED", "The extracted WAV could not be read.", retryable=False, status_code=422) from exc
    if channels != 1 or sample_rate <= 0 or frame_count <= 0 or sample_width not in {1, 2, 3, 4}:
        raise ServiceError("AUDIO_READ_FAILED", "The extracted WAV has unsupported audio properties.", retryable=False, status_code=422)
    max_amplitude = float((1 << (sample_width * 8 - 1)) - 1)
    values: list[float] = []
    for offset in range(0, len(raw), sample_width):
        chunk = raw[offset : offset + sample_width]
        if len(chunk) != sample_width:
            break
        if sample_width == 1:
            value = chunk[0] - 128
        elif sample_width == 2:
            value = struct.unpack_from("<h", chunk)[0]
        elif sample_width == 3:
            value = int.from_bytes(chunk, "little", signed=True)
        else:
            value = struct.unpack_from("<i", chunk)[0]
        values.append(abs(value) / max_amplitude)
    if not values:
        raise ServiceError("AUDIO_READ_FAILED", "The extracted WAV contains no samples.", retryable=False, status_code=422)
    window_size = max(1, int(sample_rate * window_ms / 1000))
    window_energies = [sum(value * value for value in values[index : index + window_size]) / max(1, len(values[index : index + window_size])) for index in range(0, len(values), window_size)]
    average = math.sqrt(sum(window_energies) / len(window_energies))
    variance = sum((energy - sum(window_energies) / len(window_energies)) ** 2 for energy in window_energies) / len(window_energies)
    threshold = 0.01
    silent = [value < threshold for value in values]
    longest = current = 0
    pauses = 0
    for is_silent in silent:
        if is_silent:
            current += 1
        else:
            if current >= sample_rate * 0.2:
                pauses += 1
                longest = max(longest, current)
            current = 0
    if current >= sample_rate * 0.2:
        pauses += 1
        longest = max(longest, current)
    leading = next((index for index, value in enumerate(silent) if not value), len(silent))
    trailing = next((index for index, value in enumerate(reversed(silent)) if not value), len(silent))
    midpoint = max(1, len(window_energies) // 3)
    first_energy = sum(window_energies[:midpoint]) / midpoint
    next_energy = sum(window_energies[midpoint : midpoint * 2] or window_energies[:midpoint]) / len(window_energies[midpoint : midpoint * 2] or window_energies[:midpoint])
    duration_ms = int(round(len(values) * 1000 / sample_rate))
    return AudioMeasurement(
        average_energy=_bounded(average),
        energy_variance=_bounded(variance * 4),
        energy_change_at_hook=_bounded(abs(math.sqrt(first_energy) - math.sqrt(next_energy))),
        silence_ratio=_bounded(sum(silent) / len(silent)),
        longest_pause_ms=int(round(longest * 1000 / sample_rate)),
        pause_frequency=_bounded(pauses / max(1.0, duration_ms / 1000.0 * 2)),
        dead_air_start_ms=int(round(leading * 1000 / sample_rate)),
        dead_air_end_ms=int(round(trailing * 1000 / sample_rate)),
    ), duration_ms


def _audio_features(request: FeatureRequest, measurement: AudioMeasurement, duration_ms: int) -> AudioFeatures:
    words_per_minute = len(_words(request.transcript)) * 60_000 / max(1, duration_ms)
    return AudioFeatures(
        words_per_minute=words_per_minute,
        average_audio_energy=measurement.average_energy,
        energy_variance=measurement.energy_variance,
        energy_change_at_hook=measurement.energy_change_at_hook,
        silence_ratio=measurement.silence_ratio,
        longest_pause_ms=measurement.longest_pause_ms,
        pause_frequency=measurement.pause_frequency,
    )


def _structural_features(request: FeatureRequest, measurement: AudioMeasurement) -> StructuralFeatures:
    first_end = request.transcript_segments[0].end_ms
    main_point = next((segment for segment in request.transcript_segments if len(_words(segment.text)) >= 5), request.transcript_segments[0])
    payoff = next((segment for segment in reversed(request.transcript_segments) if segment.is_sentence_boundary_end), request.transcript_segments[-1])
    complete = sum(1 for segment in request.transcript_segments if segment.is_sentence_boundary_end or re.search(r"[.!?…]\s*$", segment.text.strip()))
    return StructuralFeatures(
        time_to_main_point_ms=max(0, main_point.start_ms - request.start_ms),
        intro_length_ms=max(0, first_end - request.start_ms),
        sentence_completeness=_bounded(complete / max(1, len(request.transcript_segments))),
        hook_to_payoff_time_ms=max(0, payoff.end_ms - request.start_ms),
        dead_air_start_ms=measurement.dead_air_start_ms,
        dead_air_end_ms=measurement.dead_air_end_ms,
    )


class DeterministicFeatureExtractor:
    def __init__(
        self,
        config: FeatureExtractionConfig | None = None,
        *,
        downloader: MediaDownloader | None = None,
        probe: MediaProbe | None = None,
        audio_extractor: SegmentAudioExtractor | None = None,
        visual_analyzer: VisualAnalyzer | None = None,
    ) -> None:
        try:
            self.config = config or FeatureExtractionConfig.from_env()
        except (TypeError, ValueError) as exc:
            raise ServiceError("FEATURE_CONFIG_INVALID", "Feature extraction configuration is invalid.", retryable=False, status_code=500) from exc
        self.downloader = downloader or SignedMediaDownloader()
        self.probe = probe or FFprobeMediaProbe()
        self.audio_extractor = audio_extractor or FFmpegSegmentAudioExtractor()
        self.visual_analyzer = visual_analyzer or OptionalOpenCVVisualAnalyzer()

    def extract(self, request: FeatureRequest) -> FeatureSet:
        duration_ms = request.end_ms - request.start_ms
        if duration_ms > self.config.max_candidate_duration_ms:
            raise ServiceError("INVALID_FEATURE_RANGE", "Candidate duration exceeds the configured feature extraction limit.", retryable=False, status_code=422)
        warnings: list[str] = []
        with tempfile.TemporaryDirectory(prefix="cliprank-features-") as temporary:
            directory = Path(temporary)
            source = directory / "source.media"
            audio = directory / "candidate.wav"
            self.downloader.download(
                request.media.signed_url.unicode_string(), source,
                max_bytes=self.config.max_media_bytes,
                timeout_seconds=self.config.download_timeout_seconds,
                chunk_size=1024 * 1024,
            )
            probe = self.probe.probe(source, timeout_seconds=self.config.ffprobe_timeout_seconds)
            if not probe.has_audio:
                raise ServiceError("MEDIA_HAS_NO_AUDIO", "Media does not contain an audio stream.", retryable=False, status_code=422)
            if probe.duration_ms is not None and request.end_ms > probe.duration_ms:
                raise ServiceError(
                    "INVALID_FEATURE_RANGE",
                    "Candidate bounds exceed the probed media duration.",
                    retryable=False,
                    details={"media_duration_ms": probe.duration_ms},
                    status_code=422,
                )
            self.audio_extractor.extract(source, audio, start_ms=request.start_ms, end_ms=request.end_ms, timeout_seconds=self.config.ffmpeg_timeout_seconds)
            audio_measurement, extracted_duration_ms = _read_pcm_wav(audio, self.config.audio_window_ms)
            audio_features = _audio_features(request, audio_measurement, extracted_duration_ms)
            if not probe.has_video:
                warnings.append("NO_VIDEO_STREAM")
                visual_measurement = VisualMeasurement(warnings=("VISUAL_FRAME_ANALYSIS_UNAVAILABLE", "VISUAL_FACE_DETECTION_UNAVAILABLE"))
            else:
                visual_measurement = self.visual_analyzer.analyze(source, start_ms=request.start_ms, end_ms=request.end_ms, sample_count=self.config.visual_sample_count)
            warnings.extend(visual_measurement.warnings)
        return FeatureSet(
            video_id=request.video_id,
            candidate_id=request.candidate_id,
            feature_version=request.feature_version,
            model_version=self.config.model_version,
            prompt_version=None,
            semantic=_semantic_features(request),
            audio=audio_features,
            visual=VisualFeatures(
                face_presence_ratio=_bounded(visual_measurement.face_presence_ratio),
                visual_motion=_bounded(visual_measurement.visual_motion),
                scene_change_rate=_bounded(visual_measurement.scene_change_rate),
                screen_recording_ratio=_bounded(visual_measurement.screen_recording_ratio),
                camera_change_frequency=_bounded(visual_measurement.camera_change_frequency),
                sample_count=max(0, visual_measurement.sample_count),
            ),
            structural=_structural_features(request, audio_measurement),
            capability_warnings=list(dict.fromkeys(warnings)),
        )
