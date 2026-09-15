import pytest


@pytest.fixture(autouse=True)
def service_token(monkeypatch):
    monkeypatch.setenv("ML_SERVICE_TOKEN", "development-service-token")


@pytest.fixture
def headers():
    return {
        "Authorization": "Bearer development-service-token",
        "X-Request-Id": "req-test-1",
        "Idempotency-Key": "video/1/run/1/test",
        "Content-Type": "application/json",
    }


def feature_payload(candidate_id="c1", feature_version="features-1"):
    return {
        "candidate_id": candidate_id,
        "start_ms": 0,
        "end_ms": 30000,
        "features": {
            "video_id": "v1", "candidate_id": candidate_id, "feature_version": feature_version,
            "model_version": "baseline-test", "prompt_version": None,
            "semantic": {
                "hook_strength": 0.8, "standalone_clarity": 0.9, "information_density": 0.7,
                "novelty": 0.6, "emotional_intensity": 0.5, "quotability": 0.7,
                "payoff_strength": 0.8, "story_completeness": 0.9, "technical_depth": 0.4,
                "call_to_action_presence": 0.1, "topic": "education", "content_type": "educational", "hook_type": "question",
            },
            "audio": {
                "words_per_minute": 150.0, "average_audio_energy": 0.6, "energy_variance": 0.2,
                "energy_change_at_hook": 0.1, "silence_ratio": 0.05, "longest_pause_ms": 600, "pause_frequency": 0.1,
            },
            "visual": {
                "face_presence_ratio": 0.8, "visual_motion": 0.3, "scene_change_rate": 0.1,
                "screen_recording_ratio": 0.0, "camera_change_frequency": 0.1, "sample_count": 20,
            },
            "structural": {
                "time_to_main_point_ms": 1500, "intro_length_ms": 1200, "sentence_completeness": 0.9,
                "hook_to_payoff_time_ms": 12000, "dead_air_start_ms": 0, "dead_air_end_ms": 400,
            },
            "capability_warnings": [],
        },
    }
