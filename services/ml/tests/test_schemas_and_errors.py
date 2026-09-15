from fastapi.testclient import TestClient

from app.api.schemas import TranscriptSegment
from app.main import app


def test_segment_rejects_reversed_bounds():
    try:
        TranscriptSegment(sequence=0, start_ms=10, end_ms=10, text="bad")
    except ValueError as error:
        assert "end_ms" in str(error)
    else:
        raise AssertionError("reversed timestamps must be rejected")


def test_missing_body_is_typed_error(headers):
    response = TestClient(app).post("/internal/api/v1/candidates/generate", headers=headers, json={})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "INVALID_REQUEST"


def test_invalid_token_is_typed_error(headers):
    body = {
        "contract_version": "1.0", "video_id": "v1", "duration_ms": 30000,
        "generation_version": "candidate-1", "segments": [{"sequence": 0, "start_ms": 0, "end_ms": 30000, "text": "A complete thought."}],
    }
    bad = {**headers, "Authorization": "Bearer wrong"}
    response = TestClient(app).post("/internal/api/v1/candidates/generate", headers=bad, json=body)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


def test_missing_service_token_is_typed_configuration_error(headers, monkeypatch):
    monkeypatch.delenv("ML_SERVICE_TOKEN")
    body = {
        "contract_version": "1.0", "video_id": "v1", "duration_ms": 30000,
        "generation_version": "candidate-1", "segments": [{"sequence": 0, "start_ms": 0, "end_ms": 30000, "text": "A complete thought."}],
    }
    response = TestClient(app).post("/internal/api/v1/candidates/generate", headers=headers, json=body)
    assert response.status_code == 500
    assert response.json()["error"]["code"] == "SERVICE_MISCONFIGURED"


def test_unsupported_operations_are_typed(headers):
    body = {
        "contract_version": "1.0", "video_id": "v1", "duration_ms": 1000,
        "transcript_version": "whisper-1", "media": {"signed_url": "https://storage.test/video.mp4", "mime_type": "video/mp4"},
    }
    response = TestClient(app).post("/internal/api/v1/transcriptions", headers=headers, json=body)
    assert response.status_code == 501
    assert response.json()["error"]["code"] == "UNSUPPORTED_OPERATION"
