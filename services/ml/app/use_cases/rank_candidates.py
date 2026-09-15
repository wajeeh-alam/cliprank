from app.adapters.baseline import HeuristicRanker
from app.api.schemas import RankRequest, RankedCandidate
from app.domain.errors import ServiceError
from pydantic import ValidationError


def execute(request: RankRequest, ranker=None) -> list[RankedCandidate]:
    ranker = ranker or HeuristicRanker()
    try:
        raw = ranker.rank(
            [{"candidate_id": c.candidate_id, "features": c.features.model_dump(mode="python")} for c in request.candidates],
            request.config.weights,
        )
    except ServiceError:
        raise
    except ValueError as exc:
        raise ServiceError("RANKING_INVALID_INPUT", "Ranking input could not be scored.", retryable=False, details={"reason": str(exc)}, status_code=422) from exc
    try:
        return [RankedCandidate.model_validate(item) for item in raw]
    except ValidationError as exc:
        raise ServiceError(
            "RANKING_INVALID_OUTPUT",
            "Ranker output did not satisfy the versioned response schema.",
            retryable=False,
            details={"validation_errors": [str(error) for error in exc.errors()]},
            status_code=502,
        ) from exc
