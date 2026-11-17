"""Shared test helpers: a throwaway data folder and fake clips with a known taste."""

import random

import numpy as np
import pytest

from cliprank import config
from cliprank.db import DB


@pytest.fixture
def db(tmp_path, monkeypatch):
    # Point every data folder at a temp dir, so the real app can run on it too.
    monkeypatch.setattr(config, "DATA_DIR", tmp_path)
    for name in ("UPLOADS", "CLIPS", "FRAMES", "EMB", "MODELS", "EXPORTS"):
        monkeypatch.setattr(config, name, tmp_path / name.lower())
    monkeypatch.setattr(config, "DB_PATH", tmp_path / "t.db")
    config.make_dirs()
    return DB(config.DB_PATH)


def seed_clips(db, n=40, seed=0, n_videos=8, status="ready"):
    rng = np.random.default_rng(seed)
    vids = [db.run("INSERT INTO videos (kind, filename, path, status) VALUES ('session','x','x',?)", (status,))
            for _ in range(n_videos)]
    # Like real clips: each one varies along a few hidden factors (topic, energy...),
    # and the embeddings are noisy mixtures of those factors. Taste depends on the factors.
    project = rng.normal(size=(4, 384))
    taste = rng.normal(size=4)
    ids, utility = [], {}
    for i in range(n):
        cid = db.run("INSERT INTO clips (video_id, start_ms, end_ms, text, ready) VALUES (?,0,1000,'t',1)",
                     (vids[i % n_videos],))
        factors = rng.normal(size=4) * 3
        write_features(cid, rng, text=(factors @ project + rng.normal(size=384)).astype(np.float32))
        ids.append(cid)
        utility[cid] = float(factors @ taste)
    return ids, utility


def write_features(cid, rng, text=None):
    np.savez(config.EMB / f"{cid}.npz", version=config.FEATURES_VERSION,
             text=rng.normal(size=384).astype(np.float32) if text is None else text,
             hook_text=rng.normal(size=384).astype(np.float32), screen_text=rng.normal(size=384).astype(np.float32),
             vis=rng.normal(size=512).astype(np.float32), hook_vis=rng.normal(size=512).astype(np.float32),
             scalars=rng.normal(size=12).astype(np.float32))


def swipe_by_taste(db, ids, utility, n=300, seed=0):
    rng = random.Random(seed)
    for _ in range(n):
        a, b = rng.sample(ids, 2)
        db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?,?)", (a, b, "a" if utility[a] > utility[b] else "b"))


