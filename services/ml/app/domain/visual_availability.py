"""Map visual capability warnings to the measurements they invalidate."""

from __future__ import annotations

from collections.abc import Iterable


VISUAL_FEATURES = (
    "face_presence_ratio",
    "visual_motion",
    "scene_change_rate",
    "screen_recording_ratio",
    "camera_change_frequency",
    "sample_count",
)

_WARNING_FEATURES = {
    "VISUAL_FRAME_ANALYSIS_UNAVAILABLE": frozenset(VISUAL_FEATURES),
    "VISUAL_FACE_DETECTION_UNAVAILABLE": frozenset(("face_presence_ratio",)),
    "VISUAL_SCREEN_RECORDING_CLASSIFICATION_UNAVAILABLE": frozenset(("screen_recording_ratio",)),
}


def unavailable_visual_features(warnings: Iterable[str] | None) -> frozenset[str]:
    unavailable: set[str] = set()
    for warning in warnings or ():
        unavailable.update(_WARNING_FEATURES.get(warning, ()))
    return frozenset(unavailable)
