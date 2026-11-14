"""Learns a score for each clip from your A-vs-B picks (a Bradley-Terry model).

score(clip) = w . features(clip)
P(you pick A over B) = sigmoid(score(A) - score(B))

Fitting w is plain logistic regression on (features(A) - features(B)).
"""

import json
import pickle
import random
from dataclasses import dataclass

import numpy as np
from sklearn.decomposition import PCA
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.preprocessing import StandardScaler

from cliprank import config
from cliprank.db import DB

EMBEDDINGS = ["text", "hook_text", "vis", "hook_vis"]
PCA_DIMS = 16          # each embedding is squashed to this many numbers
C = 0.1                # regularization; lower = simpler model
OLD_POST_WEIGHT = 0.3  # an old-post pair counts less than a real swipe


@dataclass
class Pair:
    a: int
    b: int
    y: int  # 1 if a won
    w: float = 1.0


def load_features(clip_ids: list[int]) -> dict[str, np.ndarray]:
    out = {k: [] for k in EMBEDDINGS + ["scalars"]}
    for cid in clip_ids:
        z = np.load(config.EMB / f"{cid}.npz")
        for k in out:
            out[k].append(z[k])
    return {k: np.stack(v) for k, v in out.items()}


def build_matrix(feats: dict[str, np.ndarray]) -> np.ndarray:
    # Embeddings have 384-512 numbers each. With ~1000 swipes that's too many
    # to learn weights for, so PCA keeps the 16 directions that vary most.
    n = len(feats["scalars"])
    parts = []
    for k in EMBEDDINGS:
        dims = max(1, min(PCA_DIMS, n - 1))
        parts.append(PCA(dims, random_state=0).fit_transform(feats[k]) if n > 1 else feats[k][:, :1] * 0)
    parts.append(feats["scalars"])
    return StandardScaler().fit_transform(np.hstack(parts))


def fit(pairs: list[Pair], X: np.ndarray, idx: dict[int, int]) -> np.ndarray:
    d = np.array([X[idx[p.a]] - X[idx[p.b]] for p in pairs])
    y = np.array([p.y for p in pairs])
    w = np.array([p.w for p in pairs])
    # Add every pair flipped too, so screen position (A on the left) can't matter.
    d, y, w = np.vstack([d, -d]), np.concatenate([y, 1 - y]), np.concatenate([w, w])
    lr = LogisticRegression(C=C, fit_intercept=False, max_iter=2000)
    lr.fit(d, y, sample_weight=w)
    return lr.coef_[0]


def accuracy(coef, pairs, X, idx) -> float | None:
    if not pairs:
        return None
    s = X @ coef
    return float(np.mean([(s[idx[p.a]] > s[idx[p.b]]) == bool(p.y) for p in pairs]))


def heldout_pair_accuracy(swipes, extra, X, idx, k=5) -> float | None:
    """5-fold: train on 80% of swipes, guess the other 20%, repeat."""
    if len(swipes) < 20:
        return None
    order = np.random.default_rng(0).permutation(len(swipes))
    accs = []
    for f in range(k):
        test = set(order[f::k].tolist())
        train = [p for i, p in enumerate(swipes) if i not in test]
        accs.append(accuracy(fit(train + extra, X, idx), [swipes[i] for i in test], X, idx))
    return float(np.mean(accs))


def heldout_clip_accuracy(swipes, extra, X, idx, rounds=10) -> float | None:
    """Hide a quarter of the clips completely, then guess pairs made only of those.

    This is the number that matters: it's how the model does on clips it has
    never seen, which is the situation when you record something new.
    """
    clips = sorted({c for p in swipes for c in (p.a, p.b)})
    accs = []
    for r in range(rounds):
        hidden = set(random.Random(r).sample(clips, max(2, len(clips) // 4)))
        train = [p for p in swipes if p.a not in hidden and p.b not in hidden]
        test = [p for p in swipes if p.a in hidden and p.b in hidden]
        if len(train) >= 10 and len(test) >= 3:
            accs.append(accuracy(fit(train + extra, X, idx), test, X, idx))
    return float(np.mean(accs)) if accs else None


def swipe_pairs(db: DB) -> list[Pair]:
    rows = db.all("SELECT a_id, b_id, choice FROM swipes WHERE choice IN ('a','b') ORDER BY id")
    return [Pair(r["a_id"], r["b_id"], int(r["choice"] == "a")) for r in rows]


def old_posts(db: DB) -> list[dict]:
    return db.all("""SELECT c.id, v.label FROM clips c JOIN videos v ON v.id = c.video_id
                     WHERE v.kind = 'library' AND v.label IS NOT NULL AND c.ready = 1""")


def consistency(db: DB) -> tuple[float | None, int]:
    """How often you picked the same winner when shown a pair again."""
    rows = db.all("SELECT a_id, b_id, choice, is_repeat FROM swipes WHERE choice IN ('a','b') ORDER BY id")
    first, same = {}, []
    for r in rows:
        winner = r["a_id"] if r["choice"] == "a" else r["b_id"]
        key = frozenset((r["a_id"], r["b_id"]))
        if r["is_repeat"] and key in first:
            same.append(first[key] == winner)
        first.setdefault(key, winner)
    return (float(np.mean(same)) if same else None), len(same)


def train(db: DB) -> dict | None:
    clip_ids = [r["id"] for r in db.all("SELECT id FROM clips WHERE ready = 1 ORDER BY id")]
    idx = {c: i for i, c in enumerate(clip_ids)}
    swipes = [p for p in swipe_pairs(db) if p.a in idx and p.b in idx]
    posts = [r for r in old_posts(db) if r["id"] in idx]
    good = [r["id"] for r in posts if r["label"] == "good"]
    bad = [r["id"] for r in posts if r["label"] == "bad"]
    post_pairs = [Pair(g, b, 1, OLD_POST_WEIGHT) for g in good for b in bad]
    if len(swipes) + len(post_pairs) < config.MIN_PAIRS_TO_TRAIN:
        return None

    feats = load_features(clip_ids)
    X = build_matrix(feats)
    coef = fit(swipes + post_pairs, X, idx)
    for cid, s in zip(clip_ids, X @ coef):
        db.run("UPDATE clips SET score = ? WHERE id = ?", (float(s), cid))

    dur = feats["scalars"][:, 0]
    cons, n_repeats = consistency(db)
    metrics = {
        "n_swipes": len(swipes),
        "n_old_post_pairs": len(post_pairs),
        "pair_accuracy": heldout_pair_accuracy(swipes, post_pairs, X, idx),
        "clip_accuracy": heldout_clip_accuracy(swipes, post_pairs, X, idx),
        "longer_wins": float(np.mean([(dur[idx[p.a]] > dur[idx[p.b]]) == bool(p.y) for p in swipes])) if swipes else None,
        "consistency": cons,
        "n_repeats": n_repeats,
        "old_posts_auc": None,
    }
    # Train on swipes only, then check whether it ranks your good posts above your bad ones.
    if len(swipes) >= config.MIN_PAIRS_TO_TRAIN and good and bad:
        s = X @ fit(swipes, X, idx)
        metrics["old_posts_auc"] = float(roc_auc_score([1] * len(good) + [0] * len(bad),
                                                       [s[idx[c]] for c in good + bad]))

    mid = db.run("INSERT INTO models (n_pairs, metrics, path) VALUES (?, ?, '')", (len(swipes), json.dumps(metrics)))
    path = config.MODELS / f"model-{mid}.pkl"
    with open(path, "wb") as f:
        pickle.dump({"clip_ids": clip_ids, "coef": coef, "metrics": metrics}, f)
    db.run("UPDATE models SET path = ? WHERE id = ?", (str(path), mid))
    return metrics
