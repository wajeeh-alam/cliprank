from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from app.api.schemas import TranscriptionRequest, TranscriptionResponse
from app.domain.errors import ServiceError
from app.domain.transcription import TranscriptionResult


def execute(request: TranscriptionRequest, transcriber: Any) -> TranscriptionResponse:
    """Call the Transcriber port, then validate the provider-independent envelope."""

    result = transcriber.transcribe(request.media.signed_url.unicode_string(), request.duration_ms, request.language)
    if isinstance(result, TranscriptionResult):
        payload = {
            "language": result.language,
            "segments": [
                {
                    "sequence": segment.sequence,
                    "start_ms": segment.start_ms,
                    "end_ms": segment.end_ms,
                    "text": segment.text,
                    "words": [
                        {"start_ms": word.start_ms, "end_ms": word.end_ms, "text": word.text}
                        for word in segment.words
                    ],
                    "is_sentence_boundary_start": segment.is_sentence_boundary_start,
                    "is_sentence_boundary_end": segment.is_sentence_boundary_end,
                }
                for segment in result.segments
            ],
        }
    elif isinstance(result, dict):
        payload = result
    else:
        payload = getattr(result, "model_dump", lambda **_: result)(mode="python")
    try:
        return TranscriptionResponse.model_validate(
            {
                "video_id": request.video_id,
                "transcript_version": request.transcript_version,
                **payload,
            }
        )
    except ValidationError as exc:
        raise ServiceError(
            "PROVIDER_INVALID_OUTPUT",
            "Transcriber output did not satisfy the versioned response schema.",
            retryable=False,
            details={"validation_errors": exc.errors()},
            status_code=502,
        ) from exc
