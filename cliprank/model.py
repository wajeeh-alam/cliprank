"""Learns a score for each clip from your A-vs-B picks (a Bradley-Terry model).

score(clip) = w . features(clip)
P(you pick A over B) = sigmoid(score(A) - score(B))

Fitting w is plain logistic regression on (features(A) - features(B)).
"""

import json
import pickle
from dataclasses import dataclass

import numpy as np
from sklearn.decomposition import PCA
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.preprocessing import StandardScaler

from cliprank import config
from cliprank.db import DB

EMBEDDINGS = ["text", "hook_text", "screen_text", "vis", "hook_vis"]
PCA_DIMS = 8           # each embedding is squashed to this many numbers
C = 0.1                # regularization; lower = simpler model
OLD_POST_WEIGHT = 0.3  # the most one old-post pair can count, vs 1 for a swipe
OLD_POSTS_SHARE = 0.25 # all old-post pairs together count as at most 25% of your swipes...
OLD_POSTS_FLOOR = 40   # ...where "your swipes" is at least 40, so they still help at the start


@dataclass
class Pair:
    a: int
    b: int
    y: int  # 1 if a won
    w: float = 1.0


class TasteModel:
    """Everything needed to score a clip: one PCA per embedding, a scaler, and the weights.

    Saved as one object so a new clip can be scored later with exactly the same
    transform, and scores don't shift just because the PCA was refit.
    """

    def __init__(self, feats: dict[str, np.ndarray], rows=None):
        rows = np.arange(len(feats["scalars"])) if rows is None else np.asarray(rows)
        self.features_version = config.FEATURES_VERSION
        self.pcas = {}
        for k in EMBEDDINGS:
            dims = min(PCA_DIMS, len(rows) - 1, feats[k].shape[1])
            self.pcas[k] = PCA(dims, random_state=0).fit(feats[k][rows]) if dims >= 1 else None
        self.scaler = StandardScaler().fit(self._raw(feats)[rows])
        self.coef = None

    def _raw(self, feats):
        n = len(feats["scalars"])
        parts = [p.transform(feats[k]) if p else np.zeros((n, 1)) for k, p in self.pcas.items()]
        return np.hstack(parts + [feats["scalars"]])

    def transform(self, feats) -> np.ndarray:
        return self.scaler.transform(self._raw(feats))

    def score(self, feats) -> np.ndarray:
        return self.transform(feats) @ self.coef


def load_features(clip_ids: list[int]) -> dict[str, np.ndarray]:
    out = {k: [] for k in EMBEDDINGS + ["scalars"]}
    for cid in clip_ids:
        z = np.load(config.EMB / f"{cid}.npz")
        for k in out:
            out[k].append(z[k])
    return {k: np.stack(v) for k, v in out.items()}


def fit(pairs: list[Pair], X: np.ndarray, idx: dict[int, int]) -> np.ndarray:
    d = np.array([X[idx[p.a]] - X[idx[p.b]] for p in pairs])
    y = np.array([p.y for p in pairs])
    w = np.array([p.w for p in pairs])
    # Add every pair flipped too, so screen position (A on the left) can't matter.
    d, y, w = np.vstack([d, -d]), np.concatenate([y, 1 - y]), np.concatenate([w, w])
    lr = LogisticRegression(C=C, fit_intercept=False, max_iter=2000)
    lr.fit(d, y, sample_weight=w)
    return lr.coef_[0]


def n_correct(scores, pairs, idx) -> int:
    return sum((scores[idx[p.a]] > scores[idx[p.b]]) == bool(p.y) for p in pairs)


def heldout_pair_accuracy(swipes, extra, X, idx, k=5) -> float | None:
    """Guess pairs it hasn't trained on (the clips themselves are known).

    Folds are split by pair, so when a pair was shown twice (a repeat), both
    swipes land on the same side and the answer can't leak into training.
    """
    if len(swipes) < 20:
        return None
    keys = sorted({tuple(sorted((p.a, p.b))) for p in swipes})
    order = np.random.default_rng(0).permutation(len(keys))
    fold = {keys[i]: n % k for n, i in enumerate(order)}
    right = total = 0
    for f in range(k):
        test = [p for p in swipes if fold[tuple(sorted((p.a, p.b)))] == f]
        train = [p for p in swipes if fold[tuple(sorted((p.a, p.b)))] != f]
        if test and train:
            right += n_correct(X @ fit(train + extra, X, idx), test, idx)
            total += len(test)
    return right / total if total else None


def heldout_video_accuracy(swipes, extra, feats, idx, video_of, k=5) -> tuple[float | None, int]:
    """The number that matters: hide whole videos, then guess picks between their clips.

    Clips from one recording overlap and look alike, so hiding single clips
    would leave near-twins in training. Hiding the whole video matches what
    happens when you upload a new recording. The PCA and scaler are also refit
    without the hidden videos. Needs swipes on at least 2 videos.
    """
    videos = sorted({video_of[c] for p in swipes for c in (p.a, p.b)})
    if len(videos) < 2:
        return None, 0
    order = np.random.default_rng(0).permutation(videos)
    right = total = 0
    for f in range(min(k, len(videos))):
        hidden = set(order[f::k].tolist())
        test = [p for p in swipes if video_of[p.a] in hidden and video_of[p.b] in hidden]
        train = [p for p in swipes if video_of[p.a] not in hidden and video_of[p.b] not in hidden]
        if len(train) < 10 or not test:
            continue
        tm = TasteModel(feats, [i for c, i in idx.items() if video_of[c] not in hidden])
        X = tm.transform(feats)
        right += n_correct(X @ fit(train + extra, X, idx), test, idx)
        total += len(test)
    return (right / total if total else None), total


def swipe_pairs(db: DB) -> list[Pair]:
    rows = db.all("SELECT a_id, b_id, choice FROM swipes WHERE choice IN ('a','b') ORDER BY id")
    return [Pair(r["a_id"], r["b_id"], int(r["choice"] == "a")) for r in rows]


def old_post_pairs(good: list[int], bad: list[int], n_swipes: int) -> list[Pair]:
    """Every good post beats every bad post, but all of them together are capped.

    20 good x 20 bad = 400 pairs. At full weight they'd outvote your real
    swipes, so the per-pair weight shrinks to keep their total under
    OLD_POSTS_SHARE of your swipe count.
    """
    n = len(good) * len(bad)
    if not n:
        return []
    w = min(OLD_POST_WEIGHT, OLD_POSTS_SHARE * max(n_swipes, OLD_POSTS_FLOOR) / n)
    return [Pair(g, b, 1, w) for g in good for b in bad]


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
    rows = db.all("""SELECT c.id, c.video_id, v.kind, v.label FROM clips c JOIN videos v ON v.id = c.video_id
                     WHERE c.ready = 1 AND v.status = 'ready' ORDER BY c.id""")
    clip_ids = [r["id"] for r in rows]
    idx = {c: i for i, c in enumerate(clip_ids)}
    video_of = {r["id"]: r["video_id"] for r in rows}
    swipes = [p for p in swipe_pairs(db) if p.a in idx and p.b in idx]
    good = [r["id"] for r in rows if r["kind"] == "library" and r["label"] == "good"]
    bad = [r["id"] for r in rows if r["kind"] == "library" and r["label"] == "bad"]
    post_pairs = old_post_pairs(good, bad, len(swipes))
    if len(swipes) + len(post_pairs) < config.MIN_PAIRS_TO_TRAIN:
        return None

    feats = load_features(clip_ids)
    tm = TasteModel(feats)
    X = tm.transform(feats)
    tm.coef = fit(swipes + post_pairs, X, idx)
    for cid, s in zip(clip_ids, X @ tm.coef):
        db.run("UPDATE clips SET score = ? WHERE id = ?", (float(s), cid))

    dur = feats["scalars"][:, 0]
    cons, n_repeats = consistency(db)
    video_acc, n_test = heldout_video_accuracy(swipes, post_pairs, feats, idx, video_of)
    metrics = {
        "n_swipes": len(swipes),
        "n_old_post_pairs": len(post_pairs),
        "old_post_pair_weight": post_pairs[0].w if post_pairs else None,
        "new_video_accuracy": video_acc,
        "n_new_video_test_pairs": n_test,
        "pair_accuracy": heldout_pair_accuracy(swipes, post_pairs, X, idx),
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
        pickle.dump({"model": tm, "clip_ids": clip_ids, "metrics": metrics}, f)
    db.run("UPDATE models SET path = ? WHERE id = ?", (str(path), mid))
    return metrics


def load_latest(db: DB) -> TasteModel | None:
    row = db.one("SELECT path FROM models WHERE path != '' ORDER BY id DESC LIMIT 1")
    if not row:
        return None
    try:
        with open(row["path"], "rb") as f:
            tm = pickle.load(f).get("model")
    except (OSError, pickle.UnpicklingError, AttributeError):
        return None  # missing file, or saved by an older version
    if not isinstance(tm, TasteModel) or tm.features_version != config.FEATURES_VERSION:
        return None
    return tm


def score_clip(db: DB, cid: int) -> float | None:
    """Score one clip with the saved model, without retraining. Used for brand-new clips."""
    tm = load_latest(db)
    return float(tm.score(load_features([cid]))[0]) if tm else None
