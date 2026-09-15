from decimal import Decimal, ROUND_HALF_UP
from typing import Any


DEFAULT_WEIGHTS = {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10}


def _mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def normalized_components(features: dict[str, Any]) -> dict[str, float]:
    semantic = features["semantic"]
    audio = features["audio"]
    visual = features["visual"]
    structural = features["structural"]
    semantic_score = _mean([
        semantic[name]
        for name in (
            "hook_strength", "standalone_clarity", "information_density", "novelty",
            "emotional_intensity", "quotability", "payoff_strength", "story_completeness",
            "technical_depth", "call_to_action_presence",
        )
    ])
    # Measurable delivery proxies are bounded and intentionally transparent.
    delivery = _mean([audio["average_audio_energy"], 1.0 - audio["silence_ratio"], 1.0 - min(audio["pause_frequency"], 1.0)])
    visual_score = _mean([visual["face_presence_ratio"], visual["visual_motion"], 1.0 - min(visual["scene_change_rate"], 1.0), 1.0 - min(visual["screen_recording_ratio"], 1.0)])
    structural_score = _mean([
        structural["sentence_completeness"],
        1.0 - min(structural["intro_length_ms"] / 60_000, 1.0),
        1.0 - min(structural["dead_air_start_ms"] / 10_000, 1.0),
        1.0 - min(structural["dead_air_end_ms"] / 10_000, 1.0),
    ])
    return {
        "semantic": max(0.0, min(1.0, semantic_score)),
        "hook": semantic["hook_strength"],
        "structural": max(0.0, min(1.0, structural_score)),
        "delivery": max(0.0, min(1.0, delivery)),
        "visual": max(0.0, min(1.0, visual_score)),
        "standalone_clarity": semantic["standalone_clarity"],
    }


def score_candidate(features: dict[str, Any], weights: dict[str, float] | None = None) -> dict[str, Any]:
    normalized = normalized_components(features)
    weights = weights or DEFAULT_WEIGHTS
    raw = sum(normalized[key] * weights[key] for key in ("semantic", "hook", "structural", "delivery", "visual"))
    clip_score = float(Decimal(str(raw * 100)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))
    return {
        "clip_score": clip_score,
        "components": {
            "content_quality": round(normalized["semantic"] * 100, 2),
            "hook": round(normalized["hook"] * 100, 2),
            "delivery": round(normalized["delivery"] * 100, 2),
            "pacing": round(normalized["structural"] * 100, 2),
            "visual_engagement": round(normalized["visual"] * 100, 2),
            "standalone_clarity": round(normalized["standalone_clarity"] * 100, 2),
        },
        "component_details": {
            key: {"weight": weights[key], "normalized": round(normalized[key], 6)}
            for key in ("semantic", "hook", "structural", "delivery", "visual")
        },
    }
