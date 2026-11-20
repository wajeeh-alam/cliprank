"""Logging posted clips and checking whether taste predicts how they did."""

import numpy as np
import pytest
from fastapi.testclient import TestClient

from cliprank import model, performance
from cliprank.server import create_app
from conftest import seed_clips, swipe_by_taste, write_features


@pytest.fixture
def client(db):
    app = create_app()
    c = TestClient(app)
    c.headers["x-token"] = app.state.token
    return c


def add_old_posts(db, labels, seed=5):
    rng = np.random.default_rng(seed)
    ids = []
    for label in labels:
        vid = db.run("INSERT INTO videos (kind, label, filename, path, status) VALUES ('library', ?, 'old.mp4', 'x', 'ready')",
                     (label,))
        cid = db.run("INSERT INTO clips (video_id, start_ms, end_ms, text, ready) VALUES (?, 0, 9000, 'old', 1)", (vid,))
        write_features(cid, rng)
        ids.append(cid)
    return ids


def test_mark_posted_and_add_numbers(db, client):
    ids, _ = seed_clips(db, n=4, n_videos=1)
    pid = client.post(f"/api/clips/{ids[0]}/post").json()["id"]
    assert client.post(f"/api/clips/{ids[0]}/post").json()["id"] == pid  # posting twice doesn't duplicate
    assert client.patch(f"/api/posts/{pid}", json={"views": 12300, "watched_pct": 41.5, "posted_on": "2026-11-01"}).status_code == 200
    assert client.patch(f"/api/posts/{pid}", json={"likes": -3}).status_code == 400
    p = client.get("/api/posts").json()["posts"][0]
    assert (p["views"], p["watched_pct"], p["posted_on"], p["likes"]) == (12300, 41.5, "2026-11-01", None)
    client.patch(f"/api/posts/{pid}", json={"views": None})  # clearing a number works
    assert client.get("/api/posts").json()["posts"][0]["views"] is None
    client.delete(f"/api/posts/{pid}")
    assert client.get("/api/posts").json()["posts"] == []
    assert client.post("/api/clips/9999/post").status_code == 404


def test_old_posts_are_offered_for_numbers(db, client):
    old = add_old_posts(db, ["good", "bad"])
    offered = [c["clip_id"] for c in client.get("/api/posts").json()["old_posts_not_added"]]
    assert sorted(offered) == sorted(old)
    client.post(f"/api/clips/{old[0]}/post")
    offered = [c["clip_id"] for c in client.get("/api/posts").json()["old_posts_not_added"]]
    assert offered == [old[1]]


def test_taste_vs_views(db):
    ids, _ = seed_clips(db, n=8, n_videos=2)
    for i, cid in enumerate(ids):
        db.run("UPDATE clips SET swipe_score = ? WHERE id = ?", (float(i), cid))
        pid = db.run("INSERT INTO posts (clip_id, views, likes) VALUES (?, ?, ?)", (cid, 1000 * (i + 1), 10 * (i + 1)))
    s = performance.summary(db)
    assert s["taste"]["views"]["rho"] == pytest.approx(1.0) and s["taste"]["views"]["n"] == 8
    assert s["taste"]["watched_pct"]["rho"] is None  # never filled in

    db.run("DELETE FROM posts WHERE clip_id IN (?, ?, ?, ?)", tuple(ids[:4]))
    assert performance.summary(db)["taste"]["views"]["rho"] is None  # 4 posts: too few to say anything


def test_good_vs_bad_median_views(db):
    good, bad = add_old_posts(db, ["good"] * 3), add_old_posts(db, ["bad"] * 2, seed=6)
    for cid, views in zip(good + bad, [5000, 9000, 7000, 1000, 3000]):
        db.run("INSERT INTO posts (clip_id, views) VALUES (?, ?)", (cid, views))
    labels = performance.summary(db)["labels"]
    assert labels["good"] == {"n": 3, "median": 7000} and labels["bad"] == {"n": 2, "median": 2000}


def test_swipe_score_ignores_good_bad_labels(db):
    # swipe_score is what gets compared with views, so the labels must not leak into it.
    ids, utility = seed_clips(db)
    swipe_by_taste(db, ids, utility)
    old = add_old_posts(db, ["good"] * 4 + ["bad"] * 4)
    model.train(db)
    before = {r["id"]: (r["score"], r["swipe_score"]) for r in db.all("SELECT id, score, swipe_score FROM clips")}

    db.run("UPDATE videos SET label = CASE label WHEN 'good' THEN 'bad' ELSE 'good' END WHERE kind = 'library'")
    model.train(db)
    after = {r["id"]: (r["score"], r["swipe_score"]) for r in db.all("SELECT id, score, swipe_score FROM clips")}

    assert all(after[c][1] == pytest.approx(before[c][1]) for c in before)  # unchanged
    assert any(after[c][0] != pytest.approx(before[c][0]) for c in old)    # the full model did use them


def test_results_show_what_was_posted(db, client):
    ids, _ = seed_clips(db, n=4, n_videos=1)
    client.post(f"/api/clips/{ids[1]}/post")
    vid = db.one("SELECT video_id FROM clips WHERE id = ?", (ids[1],))["video_id"]
    clips = [c for t in client.get(f"/api/videos/{vid}/results").json()["takes"] for c in t["clips"]]
    assert {c["id"] for c in clips if c["post_id"]} == {ids[1]}
