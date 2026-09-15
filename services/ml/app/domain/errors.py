from dataclasses import dataclass, field
from typing import Any


@dataclass
class ServiceError(Exception):
    code: str
    message: str
    retryable: bool = False
    details: dict[str, Any] = field(default_factory=dict)
    status_code: int = 400


class UnsupportedOperation(ServiceError):
    def __init__(self, operation: str):
        super().__init__(
            code="UNSUPPORTED_OPERATION",
            message=f"The {operation} operation is not configured in this service foundation.",
            retryable=False,
            details={"operation": operation},
            status_code=501,
        )
