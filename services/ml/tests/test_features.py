import shutil
import subprocess
import wave
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.adapters.features import (
    DeterministicFeatureExtractor,
    ProbeResult,
    VisualMeasurement,
)
from app.api.schemas import FeatureRequest
from app.domain.errors import ServiceError
from app.main import app
from app.use_cases.extract_features import execute


def feature_request() -> FeatureRequest:
    return FeatureRequest(
        contract_version="1.0",
        video_id="v1",
        candidate_id="c1",
        feature_version="features-1",
        media={"signed_url": "https://storage.example/video.mp4", "mime_type": "video/mp4"},
        start_ms=10_000,
        end_ms=13_000,
        transcript="How can you learn this? The lesson is surprisingly useful.",
        transcript_segments=[
            {"sequence": 0, "start_ms": 10_000, "end_ms": 11_200, "text": "How can you learn this?", "is_sentence_boundary_start": True, "is_sentence_boundary_end": True},
            {"sequence": 1, "start_ms": 11_200, "end_ms": 13_000, "text": "The lesson is surprisingly useful.", "is_sentence_boundary_start": True, "is_sentence_boundary_end": True},
        ],
    )


class FakeDownloader:
    def __init__(self):
        self.paths: list[Path] = []

    def download(self, _url, destination, **_kwargs):
        self.paths.append(destination)
        destination.write_bytes(b"media")


class FakeProbe:
    def __init__(self, *, video=True, audio=True):
        self.video = video
        self.audio = audio

    def probe(self, source, **_kwargs):
        assert source.exists()
        return ProbeResult(has_audio=self.audio, has_video=self.video, duration_ms=13_000)


class FakeAudioExtractor:
    def __init__(self):
        self.paths: list[Path] = []

    def extract(self, _source, destination, **_kwargs):
        self.paths.append(destination)
        sample_rate = 16_000
        # 3 seconds of deterministic PCM: a short quiet lead-in, then signal,
        # then a quiet tail. This exercises energy, silence, and dead-air fields.
        samples = [0] * 4000 + [12000] * 36_000 + [0] * 8000
        with wave.open(str(destination), "wb") as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(sample_rate)
            stream.writeframes(b"".join(int(sample).to_bytes(2, "little", signed=True) for sample in samples))


class FakeVisualAnalyzer:
    def analyze(self, source, **_kwargs):
        assert source.exists()
        return VisualMeasurement(
            face_presence_ratio=0.25,
            visual_motion=0.4,
            scene_change_rate=0.1,
            screen_recording_ratio=0.0,
            camera_change_frequency=0.2,
            sample_count=4,
            warnings=("VISUAL_FACE_DETECTION_UNAVAILABLE",),
        )


def test_feature_extraction_uses_measured_audio_and_cleans_temporary_files():
    downloader = FakeDownloader()
    audio = FakeAudioExtractor()
    extractor = DeterministicFeatureExtractor(
        downloader=downloader,
        probe=FakeProbe(),
        audio_extractor=audio,
        visual_analyzer=FakeVisualAnalyzer(),
    )
    result = extractor.extract(feature_request())

    assert result.semantic.hook_type == "question"
    assert result.semantic.topic == "educational"
    assert result.audio.words_per_minute > 0
    assert result.audio.average_audio_energy > 0
    assert result.audio.silence_ratio > 0
    assert result.structural.time_to_main_point_ms == 0
    assert result.structural.hook_to_payoff_time_ms == 3000
    assert result.visual.sample_count == 4
    assert "VISUAL_FACE_DETECTION_UNAVAILABLE" in result.capability_warnings
    assert all(not path.exists() for path in downloader.paths + audio.paths)


def test_missing_video_is_explicit_capability_warning():
    extractor = DeterministicFeatureExtractor(
        downloader=FakeDownloader(),
        probe=FakeProbe(video=False),
        audio_extractor=FakeAudioExtractor(),
        visual_analyzer=FakeVisualAnalyzer(),
    )
    result = extractor.extract(feature_request())
    assert result.visual.sample_count == 0
    assert result.visual.visual_motion == 0
    assert "NO_VIDEO_STREAM" in result.capability_warnings
    assert "VISUAL_FRAME_ANALYSIS_UNAVAILABLE" in result.capability_warnings


def test_missing_audio_is_non_retryable_and_does_not_invoke_ffmpeg():
    class ExplodingAudio:
        def extract(self, *_args, **_kwargs):
            raise AssertionError("audio extraction must not run without an audio stream")

    extractor = DeterministicFeatureExtractor(
        downloader=FakeDownloader(), probe=FakeProbe(audio=False), audio_extractor=ExplodingAudio()
    )
    with pytest.raises(ServiceError) as raised:
        extractor.extract(feature_request())
    assert raised.value.code == "MEDIA_HAS_NO_AUDIO"
    assert raised.value.retryable is False


def test_feature_use_case_rejects_unvalidated_provider_output():
    class InvalidExtractor:
        def extract(self, _request):
            return {"semantic": {"hook_strength": 2.0}}

    with pytest.raises(ServiceError) as raised:
        execute(feature_request(), InvalidExtractor())
    assert raised.value.code == "FEATURE_PROVIDER_INVALID_OUTPUT"
    assert raised.value.retryable is False


def test_feature_api_returns_validated_envelope(headers, monkeypatch):
    import app.api.routes as routes

    extractor = DeterministicFeatureExtractor(
        downloader=FakeDownloader(),
        probe=FakeProbe(video=False),
        audio_extractor=FakeAudioExtractor(),
    )
    monkeypatch.setattr(routes, "_feature_extractor", extractor)
    response = TestClient(app).post(
        "/internal/api/v1/candidates/features",
        headers=headers,
        json=feature_request().model_dump(mode="json"),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["contract_version"] == "1.0"
    assert body["request_id"] == "req-test-1"
    assert body["idempotency_key"] == "video/1/run/1/test"
    assert body["data"]["video_id"] == "v1"
    assert body["data"]["audio"]["average_audio_energy"] > 0
    assert "NO_VIDEO_STREAM" in body["data"]["capability_warnings"]


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="FFmpeg is provided by the ML container")
def test_real_ffmpeg_and_opencv_extract_measured_features(tmp_path):
    media = tmp_path / "synthetic.mp4"
    subprocess.run(
        [
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=16000:duration=3",
            "-c:v", "mpeg4", "-c:a", "aac", "-shortest", "-y", str(media),
        ],
        check=True,
        capture_output=True,
    )

    class LocalMediaDownloader:
        def download(self, _url, destination, **_kwargs):
            shutil.copyfile(media, destination)

    payload = feature_request().model_dump(mode="python")
    payload["start_ms"] = 0
    payload["end_ms"] = 3_000
    payload["transcript_segments"][0].update(start_ms=0, end_ms=1_200)
    payload["transcript_segments"][1].update(start_ms=1_200, end_ms=3_000)
    extractor = DeterministicFeatureExtractor(downloader=LocalMediaDownloader())
    result = extractor.extract(FeatureRequest.model_validate(payload))

    assert result.audio.average_audio_energy > 0
    assert result.audio.silence_ratio < 1
    assert result.visual.sample_count >= 2
    assert result.visual.visual_motion > 0
    assert "VISUAL_FRAME_ANALYSIS_UNAVAILABLE" not in result.capability_warnings
    assert "VISUAL_SCREEN_RECORDING_CLASSIFICATION_UNAVAILABLE" in result.capability_warnings
