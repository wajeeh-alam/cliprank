"""The web app, end to end through its HTTP API (no real videos or models needed)."""

import shutil
import subprocess

import pytest
from fastapi.testclient import TestClient

from cliprank import config, model
from cliprank.server import create_app
from conftest import seed_clips, swipe_by_taste


@pytest.fixture
def client(db):
    app = create_app()
    c = TestClient(app)
    c.headers["x-token"] = app.state.token
    return c


def test_needs_login(db):
    app = create_app()
    anon = TestClient(app)
    assert anon.get("/api/pair").status_code == 401
    assert anon.get("/").status_code == 401  # shows the "not signed in" page
    # The QR link sets a cookie, then everything works.
    assert anon.get(f"/login?t={app.state.token}").status_code == 200
    assert anon.get("/api/pair").status_code == 200


def test_swipe_then_undo_brings_the_pair_back(db, client):
    seed_clips(db, n=6, n_videos=2)
    p = client.get("/api/pair").json()
    r = client.post("/api/swipe", json={"a": p["a"]["id"], "b": p["b"]["id"], "choice": "a", "decision_ms": 900})
    assert r.json()["swipes"] == 1
    back = client.post("/api/undo").json()
    assert back["swipes"] == 0 and {back["a"]["id"], back["b"]["id"]} == {p["a"]["id"], p["b"]["id"]}
    assert client.post("/api/swipe", json={"a": 1, "b": 2, "choice": "maybe"}).status_code == 400


def test_swipes_survive_a_restart_mid_processing(db, client):
    # A video that's still processing can't be swiped on, so when a restart
    # deletes and remakes its clips, there are no swipes to lose.
    seed_clips(db, n=4, n_videos=1, status="processing")
    assert client.get("/api/pair").json()["a"] is None
    db.run("UPDATE videos SET status = 'ready'")
    p = client.get("/api/pair").json()
    client.post("/api/swipe", json={"a": p["a"]["id"], "b": p["b"]["id"], "choice": "b"})
    assert db.one("SELECT COUNT(*) AS n FROM swipes")["n"] == 1


def test_results_rank_takes_best_first(db, client):
    ids, utility = seed_clips(db, n=40, n_videos=8)
    vid = db.one("SELECT video_id FROM clips WHERE id = ?", (ids[0],))["video_id"]
    mine = [c["id"] for c in db.all("SELECT id FROM clips WHERE video_id = ? ORDER BY id", (vid,))]
    db.run(f"UPDATE clips SET take = 0 WHERE id IN ({mine[0]}, {mine[1]})")  # two versions of one take
    db.run(f"UPDATE clips SET take = 1 WHERE id IN ({','.join(map(str, mine[2:]))})")
    swipe_by_taste(db, ids, utility)
    model.train(db)

    r = client.get(f"/api/videos/{vid}/results").json()
    assert r["scored"] and len(r["takes"]) == 2
    bests = [t["clips"][0]["score"] for t in r["takes"]]
    assert bests == sorted(bests, reverse=True)  # best take first
    for t in r["takes"]:
        scores = [c["score"] for c in t["clips"]]
        assert scores == sorted(scores, reverse=True)  # best version first
        assert all(0 <= c["percentile"] <= 1 for c in t["clips"])
    assert client.get("/api/videos/9999/results").status_code == 404


def test_export_explains_when_the_original_is_gone(db, client):
    ids, _ = seed_clips(db, n=2, n_videos=1)
    r = client.post(f"/api/clips/{ids[0]}/export")
    assert r.status_code == 404 and "original upload is gone" in r.json()["detail"]


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="needs ffmpeg")
def test_export_cuts_full_quality_from_the_original(db, client):
    ids, _ = seed_clips(db, n=2, n_videos=1)
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=s=1080x1920:d=3", "-f", "lavfi",
                    "-i", "sine=d=3", "-c:v", "libx264", "-c:a", "aac", str(config.UPLOADS / "orig.mp4")], check=True)
    db.run("UPDATE videos SET path = 'orig.mp4', filename = 'my take.mov'")
    db.run("UPDATE clips SET start_ms = 500, end_ms = 2500 WHERE id = ?", (ids[0],))

    assert client.post(f"/api/clips/{ids[0]}/export").json()["url"] == f"/media/export/{ids[0]}"
    r = client.get(f"/media/export/{ids[0]}")
    assert r.status_code == 200 and r.headers["content-type"] == "video/mp4"
    assert "my%20take-0s-2s.mp4" in r.headers["content-disposition"]
    size = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height",
                           "-of", "csv=p=0", str(config.EXPORTS / f"{ids[0]}.mp4")], capture_output=True, text=True)
    assert size.stdout.strip() == "1080,1920"  # original resolution, not the 720p preview
