"""Bradley-Terry preference model over clip features.

Each clip gets a score s(x) = w . x. The probability you pick A over B is
sigmoid(s_A - s_B). That's logistic regression on feature differences with no
intercept — the same "reward model" step used in RLHF, minus the RL.
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

BLOCKS = ["text", "hook_text", "vis", "hook_vis"]
PCA_DIMS = 16
LIBRARY_PAIR_WEIGHT = 0.3
C_GRID = [0.03, 0.1, 0.3, 1.0]


@dataclass
class Pair:
    a: int
    b: int
    y: int  # 1 if a won
    w: float = 1.0


# ---------- features ----------

def load_raw(clip_ids: list[int]) -> dict[str, np.ndarray]:
    blocks = {k: [] for k in BLOCKS + ["scalars"]}
    for cid in clip_ids:
        z = np.load(config.EMB / f"{cid}.npz")
        for k in blocks:
            blocks[k].append(z[k])
    return {k: np.stack(v) for k, v in blocks.items()}


def build_matrix(raw: dict[str, np.ndarray]) -> np.ndarray:
    """Compress each embedding block with PCA so ~1000 swipes can fit it."""
    n = raw["scalars"].shape[0]
    parts = []
    for k in BLOCKS:
        dims = max(1, min(PCA_DIMS, n - 1, raw[k].shape[1]))
        parts.append(PCA(n_components=dims, random_state=0).fit_transform(raw[k]) if n > 1 else raw[k][:, :1] * 0)
    parts.append(raw["scalars"])
    return StandardScaler().fit_transform(np.hstack(parts)).astype(np.float32)


# ---------- fitting ----------

def _design(pairs: list[Pair], X: np.ndarray, idx: dict[int, int]):
    d = np.array([X[idx[p.a]] - X[idx[p.b]] for p in pairs])
    y = np.array([p.y for p in pairs])
    w = np.array([p.w for p in pairs])
    # Symmetrize so the model can't learn a left/right (A/B position) bias.
    return np.vstack([d, -d]), np.concatenate([y, 1 - y]), np.concatenate([w, w])


def fit(pairs: list[Pair], X: np.ndarray, idx: dict[int, int], C: float) -> np.ndarray:
    D, y, w = _design(pairs, X, idx)
    if len(set(y)) < 2:
        return np.zeros(X.shape[1])
    lr = LogisticRegression(C=C, fit_intercept=False, max_iter=2000)
    lr.fit(D, y, sample_weight=w)
    return lr.coef_[0]


def pair_accuracy(coef: np.ndarray, pairs: list[Pair], X: np.ndarray, idx: dict[int, int]) -> float:
    if not pairs:
        return float("nan")
    s = X @ coef
    return float(np.mean([(s[idx[p.a]] > s[idx[p.b]]) == bool(p.y) for p in pairs]))


def _folds(n: int, k: int, seed: int = 0) -> list[np.ndarray]:
    order = np.random.default_rng(seed).permutation(n)
    return [order[i::k] for i in range(k)]


def cv_accuracy(swipes: list[Pair], extra: list[Pair], X, idx, C, k=5, frac=1.0) -> float:
    if len(swipes) < k * 2:
        return float("nan")
    accs = []
    rng = random.Random(1)
    for test_ix in _folds(len(swipes), k):
        test_set = set(test_ix.tolist())
        train = [p for i, p in enumerate(swipes) if i not in test_set]
        train = rng.sample(train, max(2, int(len(train) * frac)))
        coef = fit(train + extra, X, idx, C)
        accs.append(pair_accuracy(coef, [swipes[i] for i in test_ix], X, idx))
    return float(np.mean(accs))


def unseen_clip_accuracy(swipes, extra, X, idx, C, splits=10) -> float:
    """Hold out whole clips: does the model generalize to clips it has never seen?"""
    clips = sorted({c for p in swipes for c in (p.a, p.b)})
    accs = []
    for s in range(splits):
        rng = random.Random(s)
        test_clips = set(rng.sample(clips, max(2, len(clips) // 4)))
        train = [p for p in swipes if p.a not in test_clips and p.b not in test_clips]
        test = [p for p in swipes if p.a in test_clips and p.b in test_clips]
        if len(train) >= 10 and len(test) >= 3:
            accs.append(pair_accuracy(fit(train + extra, X, idx, C), test, X, idx))
    return float(np.mean(accs)) if accs else float("nan")


# ---------- data from the db ----------

def swipe_pairs(db: DB) -> list[Pair]:
    rows = db.all("SELECT a_id, b_id, choice FROM swipes WHERE choice IN ('a','b') ORDER BY id")
    return [Pair(r["a_id"], r["b_id"], 1 if r["choice"] == "a" else 0) for r in rows]


def library_pairs(db: DB) -> list[Pair]:
    rows = db.all("""SELECT c.id, v.label FROM clips c JOIN videos v ON v.id=c.video_id
                     WHERE v.kind='library' AND v.label IS NOT NULL AND c.ready=1""")
    good = [r["id"] for r in rows if r["label"] == "good"]
    bad = [r["id"] for r in rows if r["label"] == "bad"]
    return [Pair(g, b, 1, LIBRARY_PAIR_WEIGHT) for g in good for b in bad]


def self_consistency(db: DB) -> tuple[float, int]:
    """Agreement between a repeated pair and your earlier answer: the accuracy ceiling."""
    rows = db.all("SELECT a_id, b_id, choice, is_repeat FROM swipes WHERE choice IN ('a','b') ORDER BY id")
    first: dict[tuple[int, int], int] = {}
    agree = []
    for r in rows:
        winner = r["a_id"] if r["choice"] == "a" else r["b_id"]
        key = tuple(sorted((r["a_id"], r["b_id"])))
        if r["is_repeat"] and key in first:
            agree.append(first[key] == winner)
        elif key not in first:
            first[key] = winner
    return (float(np.mean(agree)) if agree else float("nan")), len(agree)


def _baseline(swipes: list[Pair], raw: dict, idx: dict, col: int) -> float:
    sc = raw["scalars"][:, col]
    return float(np.mean([(sc[idx[p.a]] > sc[idx[p.b]]) == bool(p.y) for p in swipes])) if swipes else float("nan")


def train(db: DB) -> dict | None:
    swipes = swipe_pairs(db)
    lib = library_pairs(db)
    if len(swipes) + len(lib) < config.MIN_PAIRS_TO_TRAIN:
        return None

    clip_ids = [r["id"] for r in db.all("SELECT id FROM clips WHERE ready=1 ORDER BY id")]
    idx = {c: i for i, c in enumerate(clip_ids)}
    swipes = [p for p in swipes if p.a in idx and p.b in idx]
    lib = [p for p in lib if p.a in idx and p.b in idx]
    raw = load_raw(clip_ids)
    X = build_matrix(raw)

    # Pick regularization by CV (slightly optimistic; fine at this scale).
    scored = {C: cv_accuracy(swipes, lib, X, idx, C) for C in C_GRID}
    valid = {C: a for C, a in scored.items() if not np.isnan(a)}
    C = max(valid, key=valid.get) if valid else 0.1

    coef = fit(swipes + lib, X, idx, C)
    scores = X @ coef
    for cid, s in zip(clip_ids, scores):
        db.run("UPDATE clips SET score=? WHERE id=?", (float(s), cid))

    consistency, n_repeats = self_consistency(db)
    metrics = {
        "n_swipes": len(swipes),
        "n_library_pairs": len(lib),
        "n_clips": len(clip_ids),
        "C": C,
        "cv_accuracy": valid.get(C, float("nan")),
        "unseen_clip_accuracy": unseen_clip_accuracy(swipes, lib, X, idx, C),
        "learning_curve": {str(f): cv_accuracy(swipes, lib, X, idx, C, frac=f) for f in (0.25, 0.5, 0.75, 1.0)},
        "baseline_random": 0.5,
        "baseline_longer_wins": _baseline(swipes, raw, idx, 0),
        "baseline_faster_talking_wins": _baseline(swipes, raw, idx, 1),
        "self_consistency": consistency,
        "n_repeats": n_repeats,
        "library_auc_from_swipes": _library_transfer(db, swipes, X, idx, C),
    }
    metrics = {k: (None if isinstance(v, float) and np.isnan(v) else v) for k, v in metrics.items()}

    mid = db.run("INSERT INTO models (n_pairs, metrics, path) VALUES (?,?,?)",
                 (len(swipes), json.dumps(metrics), ""))
    path = config.MODELS / f"model-{mid}.pkl"
    with open(path, "wb") as f:
        pickle.dump({"clip_ids": clip_ids, "coef": coef, "C": C, "metrics": metrics}, f)
    db.run("UPDATE models SET path=? WHERE id=?", (str(path), mid))
    return metrics


def _library_transfer(db: DB, swipes, X, idx, C) -> float:
    """Train on raw-clip swipes only, then ask: does it rank my good posts above my bad ones?"""
    rows = db.all("""SELECT c.id, v.label FROM clips c JOIN videos v ON v.id=c.video_id
                     WHERE v.kind='library' AND v.label IS NOT NULL AND c.ready=1""")
    rows = [r for r in rows if r["id"] in idx]
    labels = [1 if r["label"] == "good" else 0 for r in rows]
    if len(swipes) < config.MIN_PAIRS_TO_TRAIN or len(set(labels)) < 2:
        return float("nan")
    s = X @ fit(swipes, X, idx, C)
    return float(roc_auc_score(labels, [s[idx[r["id"]]] for r in rows]))
