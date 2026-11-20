"""How posted clips actually did, and whether your taste predicts it.

Taste here is `swipe_score`: the model trained on your swipes alone, so your
good/bad labels on old posts can't leak into the comparison.
"""

import numpy as np
from scipy.stats import spearmanr

from cliprank.db import DB

NUMBERS = ["views", "likes", "comments", "shares", "saves", "watched_pct"]
MIN_POSTS = 5  # fewer than this and a correlation means nothing


def posts(db: DB) -> list[dict]:
    rows = db.all("""SELECT p.*, c.text, c.swipe_score, c.start_ms, c.end_ms, v.kind, v.label, v.filename
                     FROM posts p JOIN clips c ON c.id = p.clip_id JOIN videos v ON v.id = c.video_id
                     ORDER BY COALESCE(p.posted_on, '') DESC, p.id DESC""")
    for r in rows:
        r["poster"] = f"/media/thumb/{r['clip_id']}"
        r["url_clip"] = f"/media/clip/{r['clip_id']}"
        engaged = [r[k] for k in ("likes", "comments", "shares", "saves") if r[k] is not None]
        r["engagement"] = sum(engaged) / r["views"] if engaged and r["views"] else None
    return rows


def correlation(pairs) -> dict:
    """Spearman rank correlation: do higher taste scores go with higher numbers?"""
    pairs = [(a, b) for a, b in pairs if a is not None and b is not None]
    out = {"n": len(pairs), "rho": None, "p": None}
    if len(pairs) >= MIN_POSTS and len({b for _, b in pairs}) > 1 and len({a for a, _ in pairs}) > 1:
        rho, p = spearmanr([a for a, _ in pairs], [b for _, b in pairs])
        out["rho"], out["p"] = float(rho), float(p)
    return out


def summary(db: DB) -> dict:
    rows = posts(db)
    taste = {k: correlation([(r["swipe_score"], r[k]) for r in rows]) for k in ("views", "watched_pct", "engagement")}

    def median_views(label):
        v = [r["views"] for r in rows if r["label"] == label and r["views"] is not None]
        return {"n": len(v), "median": float(np.median(v)) if v else None}

    return {
        "n_posts": len(rows),
        "n_with_views": sum(r["views"] is not None for r in rows),
        "has_taste": any(r["swipe_score"] is not None for r in rows),
        "taste": taste,
        "labels": {"good": median_views("good"), "bad": median_views("bad")},
    }
