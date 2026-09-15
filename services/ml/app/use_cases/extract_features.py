from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from app.api.schemas import FeatureRequest, FeatureSet
from app.domain.errors import ServiceError


def execute(request: FeatureRequest, extractor: Any) -> FeatureSet:
    try:
        result = extractor.extract(request)
        return FeatureSet.model_validate(result)
    except ServiceError:
        raise
    except ValidationError as exc:
        raise ServiceError(
            "FEATURE_PROVIDER_INVALID_OUTPUT",
            "Feature extraction output did not satisfy the versioned schema.",
            retryable=False,
            details={"validation_errors": exc.errors()},
            status_code=502,
        ) from exc
    except Exception as exc:
        raise ServiceError("FEATURE_EXTRACTION_FAILED", "Feature extraction failed.", retryable=True, status_code=502) from exc
