import random

import numpy as np
import pytest

from cliprank import model, pairs
from cliprank.candidates import Word, make_clips, sentences_from_words, split_takes
from conftest import seed_clips, swipe_by_taste, write_features


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
    wins = make_clips(sents, t2, 8000, 20000, 2500, 50)
    assert wins
    boundary = t
    for w in wins:
        assert 8000 <= w.duration_ms <= 20000 + 500  # plus edge padding
        assert not (w.start_ms + 150 < boundary < w.end_ms - 350), "clip crosses two takes"


# Model, on fake clips where the "right" answer is known

def test_model_learns_a_consistent_taste(db):
    ids, utility = seed_clips(db)
    swipe_by_taste(db, ids, utility)
    m = model.train(db)
    assert m["n_swipes"] == 300
    assert m["new_video_accuracy"] > 0.7 and m["n_new_video_test_pairs"] >= 20
    assert m["pair_accuracy"] > 0.7
    assert all(r["score"] is not None for r in db.all("SELECT score FROM clips"))


def test_new_video_accuracy_needs_two_videos(db):
    # With one recording there's nothing honest to test on, so it says so instead of guessing.
    ids, utility = seed_clips(db, n_videos=1)
    swipe_by_taste(db, ids, utility)
    m = model.train(db)
    assert m["new_video_accuracy"] is None and m["pair_accuracy"] is not None


def test_saved_model_scores_a_new_clip(db):
    ids, utility = seed_clips(db)
    swipe_by_taste(db, ids, utility)
    model.train(db)
    # The saved model gives the same score training did...
    trained = db.one("SELECT score FROM clips WHERE id = ?", (ids[0],))["score"]
    assert model.score_clip(db, ids[0]) == pytest.approx(trained)
    # ...and can score a clip it has never seen, without retraining.
    vid = db.run("INSERT INTO videos (kind, filename, path, status) VALUES ('session','y','y','ready')")
    new = db.run("INSERT INTO clips (video_id, start_ms, end_ms, text, ready) VALUES (?,0,1000,'t',1)", (vid,))
    write_features(new, np.random.default_rng(99))
    assert isinstance(model.score_clip(db, new), float)


def test_old_posts_cant_outvote_swipes():
    good, bad = list(range(20)), list(range(100, 120))  # 400 old-post pairs
    total = lambda pairs: sum(p.w for p in pairs)
    assert total(model.old_post_pairs(good, bad, n_swipes=0)) == pytest.approx(0.25 * 40)  # before swiping
    assert total(model.old_post_pairs(good, bad, n_swipes=200)) == pytest.approx(0.25 * 200)
    # A few posts keep the normal weight.
    assert model.old_post_pairs([1, 2], [3], n_swipes=0)[0].w == model.OLD_POST_WEIGHT


def test_no_swipes_on_a_video_still_processing(db):
    # Its clips get deleted if processing restarts, and swipes on them would go too.
    ids, _ = seed_clips(db, n=4, n_videos=1, status="processing")
    assert pairs.next_pair(db, random.Random(0)) is None
    db.run("UPDATE videos SET status = 'ready'")
    assert pairs.next_pair(db, random.Random(0)) is not None


def test_self_consistency(db):
    ids, _ = seed_clips(db, n=4)
    db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?, 'a')", (ids[0], ids[1]))
    db.run("INSERT INTO swipes (a_id, b_id, choice, is_repeat) VALUES (?,?, 'b', 1)", (ids[1], ids[0]))  # same winner
    db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?, 'a')", (ids[2], ids[3]))
    db.run("INSERT INTO swipes (a_id, b_id, choice, is_repeat) VALUES (?,?, 'a', 1)", (ids[3], ids[2]))  # flipped
    rate, n = model.consistency(db)
    assert n == 2 and rate == 0.5


def test_next_pair_avoids_seen_pairs(db):
    ids, _ = seed_clips(db, n=3)
    db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?,'a')", (ids[0], ids[1]))
    db.run("INSERT INTO swipes (a_id, b_id, choice) VALUES (?,?,'a')", (ids[0], ids[2]))
    p = pairs.next_pair(db, random.Random(0))
    assert {p["a"], p["b"]} == {ids[1], ids[2]}
