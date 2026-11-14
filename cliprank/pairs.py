"""Choose which two clips to show next.

Early on: random pairs, mostly from the same recording (so you're judging the
delivery, not the topic), favouring clips you've seen least.
Once a model exists: active learning — show the pairs the model is least sure
about, because those answers teach it the most. Some randomness stays in so it
doesn't only learn about one corner of your clips.
"""

import math
import random
from collections import Counter

from cliprank.db import DB

ACTIVE_AFTER = 60       # decisive swipes before switching to uncertainty sampling
REPEAT_RATE = 0.05      # re-ask an old pair this often to measure your consistency
EXPLORE_RATE = 0.2
SAME_VIDEO_RATE = 0.8
CANDIDATES = 300


def next_pair(db: DB, rng: random.Random | None = None) -> dict | None:
    rng = rng or random.Random()
    clips = db.all("""SELECT c.id, c.video_id, c.score FROM clips c JOIN videos v ON v.id=c.video_id
                      WHERE c.ready=1 AND v.kind='session'""")
    if len(clips) < 2:
        return None

    history = db.all("SELECT a_id, b_id, choice, is_repeat FROM swipes ORDER BY id")
    decisive = [h for h in history if h["choice"] in ("a", "b")]
    seen_pairs = {tuple(sorted((h["a_id"], h["b_id"]))) for h in history}
    shown = Counter()
    for h in history:
        shown[h["a_id"]] += 1
        shown[h["b_id"]] += 1

    # Repeat an old (not too recent) decisive pair, with sides flipped.
    if len(decisive) > 30 and rng.random() < REPEAT_RATE:
        old = rng.choice(decisive[:-20])
        return {"a": old["b_id"], "b": old["a_id"], "is_repeat": True}

    by_id = {c["id"]: c for c in clips}
    by_video: dict[int, list[int]] = {}
    for c in clips:
        by_video.setdefault(c["video_id"], []).append(c["id"])

    def sample_pair():
        if rng.random() < SAME_VIDEO_RATE:
            pool = [v for v in by_video.values() if len(v) >= 2]
            if pool:
                return tuple(rng.sample(rng.choice(pool), 2))
        return tuple(c["id"] for c in rng.sample(clips, 2))

    candidates = []
    for _ in range(CANDIDATES):
        a, b = sample_pair()
        if tuple(sorted((a, b))) not in seen_pairs:
            candidates.append((a, b))
    if not candidates:  # every pair seen: allow repeats rather than stall
        candidates = [sample_pair() for _ in range(20)]

    has_scores = all(by_id[c]["score"] is not None for pair in candidates for c in pair)
    use_active = len(decisive) >= ACTIVE_AFTER and has_scores and rng.random() > EXPLORE_RATE

    def coverage(pair):  # lower is better: prefer rarely shown clips
        return shown[pair[0]] + shown[pair[1]]

    if use_active:
        def uncertainty(pair):
            diff = by_id[pair[0]]["score"] - by_id[pair[1]]["score"]
            p = 1 / (1 + math.exp(-diff))
            return abs(p - 0.5) + 0.01 * coverage(pair)
        a, b = min(candidates, key=uncertainty)
    else:
        lowest = min(coverage(p) for p in candidates)
        a, b = rng.choice([p for p in candidates if coverage(p) <= lowest + 1])

    if rng.random() < 0.5:
        a, b = b, a
    return {"a": a, "b": b, "is_repeat": False}
