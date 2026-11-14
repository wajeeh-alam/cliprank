import random

import numpy as np
import pytest

from cliprank import config, model, pairs
from cliprank.candidates import Word, generate_windows, sentences_from_words, split_takes
from cliprank.db import DB


def words_for(sentences, start=0, gap=200, word_ms=300):
    out, t = [], start
    for s in sentences:
        toks = s.split()
        for i, tok in enumerate(toks):
            out.append(Word(t, t + word_ms, tok))
            t += word_ms + 50
        t += gap
    return out, t


def test_sentences_and_takes():
    w1, t = words_for(["This is take one.", "It has two sentences."])
    w2, _ = words_for(["Take two starts after a pause."], start=t + 4000)
    sents = sentences_from_words(w1 + w2)
    assert [s.text for s in sents] == ["This is take one.", "It has two sentences.", "Take two starts after a pause."]
    assert len(split_takes(sents, 2500)) == 2


def test_windows_respect_takes_and_lengths():
    take1, t = words_for(["word " * 10 + "end."] * 6)
    take2, t2 = words_for(["other " * 10 + "end."] * 6, start=t + 5000)
    sents = sentences_from_words(take1 + take2)
    wins = generate_windows(sents, t2, 8000, 20000, 2500, 50, pad_start_ms=0, pad_end_ms=0)
    assert wins
    boundary = t
    for w in wins:
        assert 8000 <= w.duration_ms <= 20000
        assert not (w.start_ms < boundary < w.end_ms), "a clip crossed the pause between takes"


# ---------- model on synthetic preferences ----------

@pytest.fixture
def db(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "EMB", tmp_path / "emb")
    monkeypatch.setattr(config, "MODELS", tmp_path / "models")
    config.EMB.mkdir()
    config.MODELS.mkdir()
    return DB(tmp_path / "t.db")


def seed_clips(db, n=40, seed=0):
    rng = np.random.default_rng(seed)
    vid = db.run("INSERT INTO videos (kind, filename, path, status) VALUES ('session','x','x','ready')")
    taste = rng.normal(size=384)
    ids, utility = [], {}
    for _ in range(n):
        cid = db.run("INSERT INTO clips (video_id, start_ms, end_ms, text, ready) VALUES (?,0,1000,'t',1)", (vid,))
        text = rng.normal(size=384).astype(np.float32)
        np.savez(config.EMB / f"{cid}.npz", text=text, hook_text=rng.normal(size=384).astype(np.float32),
                 vis=rng.normal(size=512).astype(np.float32), hook_vis=rng.normal(size=512).astype(np.float32),
                 scalars=rng.normal(size=6).astype(np.float32))
        ids.append(cid)
        utility[cid] = float(text @ taste)
    return ids, utility


def test_model_learns_a_consistent_taste(db):
    ids, utility = seed_clips(db)
    rng = random.Random(0)
    for _ in range(300):
        a, b = rng.sample(ids, 2)
        db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?,?)",
               (a, b, "a" if utility[a] > utility[b] else "b"))
    m = model.train(db)
    assert m["cv_accuracy"] > 0.7
    assert m["n_swipes"] == 300
    scored = db.all("SELECT id, score FROM clips")
    assert all(r["score"] is not None for r in scored)


def test_self_consistency(db):
    ids, _ = seed_clips(db, n=4)
    db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?, 'a')", (ids[0], ids[1]))
    db.run("INSERT INTO swipes (a_id, b_id, choice, is_repeat) VALUES (?,?, 'b', 1)", (ids[1], ids[0]))  # same winner
    db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?, 'a')", (ids[2], ids[3]))
    db.run("INSERT INTO swipes (a_id, b_id, choice, is_repeat) VALUES (?,?, 'a', 1)", (ids[3], ids[2]))  # flipped
    rate, n = model.self_consistency(db)
    assert n == 2 and rate == 0.5


def test_next_pair_avoids_seen_pairs(db):
    ids, _ = seed_clips(db, n=3)
    db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?,'a')", (ids[0], ids[1]))
    db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?,'a')", (ids[0], ids[2]))
    p = pairs.next_pair(db, random.Random(0))
    assert {p["a"], p["b"]} == {ids[1], ids[2]}
