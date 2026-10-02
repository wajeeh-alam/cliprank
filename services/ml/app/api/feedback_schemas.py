from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


def _timestamp(value):
    if isinstance(value, str):
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    return value


Timestamp = Annotated[datetime, BeforeValidator(_timestamp)]


class OutcomeSnapshot(StrictModel):
    snapshot_id: str = Field(min_length=1)
    observed_at: Timestamp
    post_age_hours: float = Field(ge=0)
    views: int | None = Field(default=None, ge=0)


class OutcomePublication(StrictModel):
    publication_id: str = Field(min_length=1)
    account_id: str = Field(min_length=1)
    source_video_id: str = Field(min_length=1)
    published_at: Timestamp
    features: dict[str, Any]
    schema_version: str = Field(min_length=1)
    baseline_score: float = Field(ge=0, le=100)
    snapshots: list[OutcomeSnapshot]


class FeedbackTrainRequest(StrictModel):
    contract_version: Literal["1.0"]
    platform: Literal["instagram", "linkedin"]
    feature_schema_version: str = Field(min_length=1)
    label_policy_version: str = Field(min_length=1)
    maturity_min_hours: float = Field(ge=0, default=60.0)
    maturity_max_hours: float = Field(gt=0, default=84.0)
    account_history_window: int = Field(ge=1, default=20)
    minimum_account_history: int = Field(ge=1, default=5)
    publications: list[OutcomePublication]

    @model_validator(mode="after")
    def valid_window(self):
        if self.maturity_max_hours <= self.maturity_min_hours:
            raise ValueError("maturity_max_hours must be greater than maturity_min_hours")
        return self


class FeedbackScoreCandidate(StrictModel):
    candidate_id: str = Field(min_length=1)
    features: dict[str, Any]


class FeedbackScoreRequest(StrictModel):
    contract_version: Literal["1.0"]
    feature_schema_version: str = Field(min_length=1)
    model_version: str = Field(min_length=1)
    artifact_sha256: str = Field(min_length=64, max_length=64)
    artifact: dict[str, Any]
    candidates: list[FeedbackScoreCandidate] = Field(min_length=1, max_length=40)

    @model_validator(mode="after")
    def unique_candidates(self):
        identifiers = [candidate.candidate_id for candidate in self.candidates]
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("candidate ids must be unique")
        return self
