from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.api.routes import router
from app.api.schemas import ErrorDetail, ErrorEnvelope
from app.domain.errors import ServiceError

app = FastAPI(title="ClipRank ML Service", version="0.1.0")
app.include_router(router)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "cliprank-ml"}


@app.exception_handler(ServiceError)
async def service_error_handler(request: Request, exc: ServiceError):
    body = ErrorEnvelope(
        request_id=request.headers.get("X-Request-Id", "unknown"),
        error=ErrorDetail(code=exc.code, message=exc.message, retryable=exc.retryable, details=exc.details),
    )
    return JSONResponse(status_code=exc.status_code, content=body.model_dump(mode="json"))


@app.exception_handler(RequestValidationError)
async def validation_error_handler(request: Request, exc: RequestValidationError):
    validation_errors = []
    for error in exc.errors():
        # Pydantic's ``ctx`` can contain a raw ValueError, which is useful in a
        # traceback but cannot be serialized into the versioned JSON envelope.
        sanitized = {key: value for key, value in error.items() if key != "ctx"}
        if "ctx" in error:
            sanitized["ctx"] = {key: str(value) for key, value in error["ctx"].items()}
        validation_errors.append(sanitized)
    body = ErrorEnvelope(
        request_id=request.headers.get("X-Request-Id", "unknown"),
        error=ErrorDetail(
            code="INVALID_REQUEST",
            message="The request did not satisfy the versioned contract.",
            retryable=False,
            details={"validation_errors": validation_errors},
        ),
    )
    return JSONResponse(status_code=422, content=body.model_dump(mode="json"))
