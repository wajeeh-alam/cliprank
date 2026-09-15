from decimal import Decimal, ROUND_HALF_UP
import math
from typing import Any


DEFAULT_WEIGHTS = {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10}
RANK_KEYS = ("semantic", "hook", "structural", "delivery", "visual")


def _mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def _bounded(value: Any, field: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{field} must be a finite number")
    try:
        numeric = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be a finite number") from exc
    if not math.isfinite(numeric):
        raise ValueError(f"{field} must be a finite number")
    return max(0.0, min(1.0, numeric))


def _nonnegative(value: Any, field: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{field} must be a finite non-negative number")
    try:
        numeric = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be a finite non-negative number") from exc
    if not math.isfinite(numeric) or numeric < 0.0:
        raise ValueError(f"{field} must be a finite non-negative number")
    return numeric


def validate_weights(weights: dict[str, float] | None = None) -> dict[str, float]:
    """Return a copy of the frozen Stage 1 heuristic weight configuration."""

    candidate = dict(DEFAULT_WEIGHTS if weights is None else weights)
    if set(candidate) != set(RANK_KEYS):
        raise ValueError("weights must define exactly the documented ranking components")
    for key in RANK_KEYS:
        value = candidate[key]
        if isinstance(value, bool):
            raise ValueError(f"weight {key} must be a finite number")
        try:
            numeric = float(value)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"weight {key} must be a finite number") from exc
        if not math.isfinite(numeric) or numeric < 0.0 or numeric > 1.0:
            raise ValueError(f"weight {key} must be between 0 and 1")
        candidate[key] = numeric
    if abs(sum(candidate.values()) - 1.0) > 1e-9:
        raise ValueError("weights must sum to 1")
    if any(abs(candidate[key] - DEFAULT_WEIGHTS[key]) > 1e-9 for key in RANK_KEYS):
        raise ValueError("weights must match the documented heuristic configuration")
    return candidate


def normalized_components(features: dict[str, Any]) -> dict[str, float]:
    try:
        semantic = features["semantic"]
        audio = features["audio"]
        visual = features["visual"]
        structural = features["structural"]
    except (KeyError, TypeError) as exc:
        raise ValueError("features must contain semantic, audio, visual, and structural sections") from exc

    def feature(section: dict[str, Any], name: str) -> float:
        try:
            return _bounded(section[name], f"{name} feature")
        except (KeyError, TypeError) as exc:
            raise ValueError(f"missing feature {name}") from exc

    def measurement(section: dict[str, Any], name: str) -> float:
        try:
            return _nonnegative(section[name], name)
        except (KeyError, TypeError) as exc:
            raise ValueError(f"missing feature {name}") from exc

    semantic_score = _mean([
        feature(semantic, name)
        for name in (
            "hook_strength", "standalone_clarity", "information_density", "novelty",
            "emotional_intensity", "quotability", "payoff_strength", "story_completeness",
            "technical_depth", "call_to_action_presence",
        )
    ])
    # Measurable delivery proxies are bounded and intentionally transparent.
    delivery = _mean([feature(audio, "average_audio_energy"), 1.0 - feature(audio, "silence_ratio"), 1.0 - feature(audio, "pause_frequency")])
    visual_score = _mean([feature(visual, "face_presence_ratio"), feature(visual, "visual_motion"), 1.0 - feature(visual, "scene_change_rate"), 1.0 - feature(visual, "screen_recording_ratio")])
    structural_score = _mean([
        feature(structural, "sentence_completeness"),
        1.0 - min(measurement(structural, "intro_length_ms") / 60_000, 1.0),
        1.0 - min(measurement(structural, "dead_air_start_ms") / 10_000, 1.0),
        1.0 - min(measurement(structural, "dead_air_end_ms") / 10_000, 1.0),
    ])
    return {
        "semantic": _bounded(semantic_score, "semantic"),
        "hook": feature(semantic, "hook_strength"),
        "structural": _bounded(structural_score, "structural"),
        "delivery": _bounded(delivery, "delivery"),
        "visual": _bounded(visual_score, "visual"),
        "standalone_clarity": feature(semantic, "standalone_clarity"),
    }


def score_candidate(features: dict[str, Any], weights: dict[str, float] | None = None) -> dict[str, Any]:
    """Calculate recommendation strength, not a probability of virality.

    Each returned component is a bounded normalized contribution. ``weight``
    records the frozen documented contribution to the 0--100 ClipScore and
    ``normalized`` records the measured feature aggregate before scaling.
    """

    normalized = normalized_components(features)
    weights = validate_weights(weights)
    raw = sum(Decimal(str(normalized[key])) * Decimal(str(weights[key])) for key in RANK_KEYS)
    clip_score = float((raw * Decimal("100")).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))
    return {
        "clip_score": max(0.0, min(100.0, clip_score)),
        "components": {
            "content_quality": max(0.0, min(100.0, round(normalized["semantic"] * 100, 2))),
            "hook": max(0.0, min(100.0, round(normalized["hook"] * 100, 2))),
            "delivery": max(0.0, min(100.0, round(normalized["delivery"] * 100, 2))),
            "pacing": max(0.0, min(100.0, round(normalized["structural"] * 100, 2))),
            "visual_engagement": max(0.0, min(100.0, round(normalized["visual"] * 100, 2))),
            "standalone_clarity": max(0.0, min(100.0, round(normalized["standalone_clarity"] * 100, 2))),
        },
        "component_details": {
            key: {"weight": weights[key], "normalized": round(_bounded(normalized[key], key), 6)}
            for key in RANK_KEYS
        },
    }
