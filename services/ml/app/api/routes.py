import hmac
import os
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request

from app.api.schemas import (
    CandidateGenerationRequest,
    Envelope,
    FeatureRequest,
    RankRequest,
    TranscriptionRequest,
)
from app.domain.errors import ServiceError
from app.use_cases import generate_candidates, rank_candidates, unsupported

router = APIRouter(prefix="/internal/api/v1")


def request_context(
    request: Request,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
    request_id: Annotated[str | None, Header(alias="X-Request-Id")] = None,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> tuple[str, str]:
    if not request_id or not request_id.strip():
        raise ServiceError("MISSING_REQUEST_ID", "X-Request-Id is required.", status_code=400)
    if not idempotency_key or not idempotency_key.strip():
        raise ServiceError("MISSING_IDEMPOTENCY_KEY", "Idempotency-Key is required.", status_code=400)
    expected = os.getenv("ML_SERVICE_TOKEN")
    if not expected:
        raise ServiceError(
            "SERVICE_MISCONFIGURED",
            "The ML service authentication token is not configured.",
            status_code=500,
        )
    if not authorization or not authorization.startswith("Bearer ") or not hmac.compare_digest(authorization[7:], expected):
        raise ServiceError("UNAUTHORIZED", "A valid service bearer token is required.", status_code=401)
    content_type = request.headers.get("content-type", "")
    if not (content_type == "application/json" or content_type.startswith("application/json;")):
        raise ServiceError("UNSUPPORTED_MEDIA_TYPE", "Requests must use application/json.", status_code=415)
    return request_id, idempotency_key


Context = Annotated[tuple[str, str], Depends(request_context)]


def envelope(request_id: str, idempotency_key: str, data: object) -> Envelope:
    return Envelope(contract_version="1.0", request_id=request_id, idempotency_key=idempotency_key, data=data)


@router.post("/transcriptions", response_model=Envelope)
def transcriptions(request: TranscriptionRequest, context: Context):
    request_id, idempotency_key = context
    unsupported.transcribe()
    return envelope(request_id, idempotency_key, {})


@router.post("/candidates/generate", response_model=Envelope)
def candidates_generate(request: CandidateGenerationRequest, context: Context):
    request_id, idempotency_key = context
    candidates, warnings = generate_candidates.execute(request)
    response = envelope(
        request_id,
        idempotency_key,
        {
            "video_id": request.video_id,
            "generation_version": request.generation_version,
            "candidates": [candidate.model_dump(mode="json") for candidate in candidates],
        },
    )
    if warnings:
        response.warnings = warnings
    return response


@router.post("/candidates/features", response_model=Envelope)
def candidates_features(request: FeatureRequest, context: Context):
    request_id, idempotency_key = context
    unsupported.extract_features()
    return envelope(request_id, idempotency_key, {})


@router.post("/rank", response_model=Envelope)
def rank(request: RankRequest, context: Context):
    request_id, idempotency_key = context
    ranked = rank_candidates.execute(request)
    return envelope(
        request_id,
        idempotency_key,
        {
            "video_id": request.video_id,
            "feature_version": request.feature_version,
            "scorer_version": request.scorer_version,
            "ranked_candidates": [candidate.model_dump(mode="json") for candidate in ranked],
        },
    )
