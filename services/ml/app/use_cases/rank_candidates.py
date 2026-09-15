from app.adapters.baseline import HeuristicRanker
from app.api.schemas import RankRequest, RankedCandidate


def execute(request: RankRequest, ranker=None) -> list[RankedCandidate]:
    ranker = ranker or HeuristicRanker()
    raw = ranker.rank(
        [{"candidate_id": c.candidate_id, "features": c.features.model_dump(mode="python")} for c in request.candidates],
        request.config.weights,
    )
    return [RankedCandidate.model_validate(item) for item in raw]
