from dataclasses import dataclass
from pathlib import Path

import pytest

from app.adapters.faster_whisper import FasterWhisperTranscriber, SignedMediaDownloader
from app.api.schemas import TranscriptionRequest
from app.domain.errors import ServiceError
from app.domain.transcription import TranscriptionConfig, TranscriptionResult, TranscriptionSegmentValue
from app.use_cases.transcribe import execute


@dataclass
class FakeWord:
    start: float
    end: float
    word: str


@dataclass
class FakeSegment:
    start: float
    end: float
    text: str
    words: list[FakeWord]


@dataclass
class FakeInfo:
    language: str


class FakeDownloader:
    def __init__(self):
        self.source_paths: list[Path] = []

    def download(self, _url, destination, **_kwargs):
        self.source_paths.append(destination)
        destination.write_bytes(b"signed-media")


class FakeExtractor:
    def __init__(self):
        self.audio_paths: list[Path] = []

    def extract(self, _source, destination, **_kwargs):
        self.audio_paths.append(destination)
        destination.write_bytes(b"pcm-wav")


def test_faster_whisper_converts_timestamps_and_cleans_temp_files():
    downloader = FakeDownloader()
    extractor = FakeExtractor()

    def load_model(name, *, device, compute_type):
        assert (name, device, compute_type) == ("tiny", "cpu", "int8")

        class Model:
            def transcribe(self, audio_path, *, language, word_timestamps):
                assert Path(audio_path).exists()
                assert language == "en"
                assert word_timestamps is True
                return iter([
                    FakeSegment(0.001, 1.2344, "Hello world.", [FakeWord(0.001, 0.4004, "Hello"), FakeWord(0.4004, 1.2344, "world.")]),
                    FakeSegment(1.5, 2.0, "Next thought", [FakeWord(1.5, 2.0, "Next thought")]),
                ]), FakeInfo("en")

        return Model()

    transcriber = FasterWhisperTranscriber(
        TranscriptionConfig(model_name="tiny", max_media_bytes=100),
        downloader=downloader,
        audio_extractor=extractor,
        model_loader=load_model,
    )
    result = transcriber.transcribe("https://storage.example/video.mp4", 3_000, "en")

    assert result.language == "en"
    assert result.segments[0].start_ms == 1
    assert result.segments[0].end_ms == 1234
    assert result.segments[0].words[0].start_ms == 1
    assert result.segments[0].words[1].end_ms == 1234
    assert result.segments[0].is_sentence_boundary_start is True
    assert result.segments[0].is_sentence_boundary_end is True
    assert result.segments[1].is_sentence_boundary_start is True
    assert result.segments[1].is_sentence_boundary_end is False
    assert all(not path.exists() for path in downloader.source_paths + extractor.audio_paths)


def test_download_errors_preserve_retryability_and_cleanup():
    class FailingDownloader:
        def download(self, *_args, **_kwargs):
            raise ServiceError("MEDIA_TOO_LARGE", "too large", retryable=False, status_code=413)

    transcriber = FasterWhisperTranscriber(downloader=FailingDownloader())
    with pytest.raises(ServiceError) as raised:
        transcriber.transcribe("https://storage.example/video.mp4", 1_000)
    assert raised.value.code == "MEDIA_TOO_LARGE"
    assert raised.value.retryable is False


def test_transcription_api_data_is_validated_and_enveloped():
    request = TranscriptionRequest(
        contract_version="1.0",
        video_id="v1",
        media={"signed_url": "https://storage.example/video.mp4", "mime_type": "video/mp4"},
        duration_ms=2_000,
        transcript_version="whisper-faster-1",
        language="en",
    )
    result = execute(
        request,
        type("Port", (), {"transcribe": lambda _self, *_args: TranscriptionResult(
            "en", (TranscriptionSegmentValue(0, 0, 500, "Hello."),)
        )})(),
    )
    assert result.video_id == "v1"
    assert result.transcript_version == "whisper-faster-1"
    assert result.model_dump(mode="json")["segments"][0]["start_ms"] == 0


def test_media_url_allows_http_only_for_explicit_internal_host():
    downloader = SignedMediaDownloader(allowed_hosts={"storage"})

    downloader._validate_url("http://storage:9000/cliprank/video.mp4?signature=test")

    with pytest.raises(ServiceError) as private_error:
        downloader._validate_url("http://127.0.0.1/video.mp4")
    assert private_error.value.code == "INVALID_MEDIA_URL"

    with pytest.raises(ServiceError) as public_http_error:
        downloader._validate_url("http://media.example.com/video.mp4")
    assert public_http_error.value.code == "INVALID_MEDIA_URL"
