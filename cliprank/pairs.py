"""Picks the next two clips to compare.

First 60 swipes: random pairs, favoring clips you've seen the least.
After that: mostly the pairs the model is least sure about (active learning),
with 20% random so it keeps seeing everything. 5% of the time it re-shows an
old pair to measure how consistent you are.
"""

import math
import random
from collections import Counter

from cliprank.db import DB

ACTIVE_AFTER = 60
REPEAT_RATE = 0.05
RANDOM_RATE = 0.2


def next_pair(db: DB, rng: random.Random | None = None) -> dict | None:
    rng = rng or random.Random()
    clips = db.all("""SELECT c.id, c.score FROM clips c JOIN videos v ON v.id = c.video_id
                      WHERE c.ready = 1 AND v.kind = 'session'""")
    if len(clips) < 2:
        return None

    history = db.all("SELECT a_id, b_id, choice FROM swipes ORDER BY id")
    decided = [h for h in history if h["choice"] in ("a", "b")]

    if len(decided) > 30 and rng.random() < REPEAT_RATE:
        old = rng.choice(decided[:-20])  # not one you just saw
        return {"a": old["b_id"], "b": old["a_id"], "is_repeat": True}

    seen = {frozenset((h["a_id"], h["b_id"])) for h in history}
    shown = Counter(c for h in history for c in (h["a_id"], h["b_id"]))
    options = []
    for _ in range(300):
        a, b = rng.sample(clips, 2)
        if frozenset((a["id"], b["id"])) not in seen:
            options.append((a, b))
    if not options:  # you've seen every pair; start repeating
        options = [tuple(rng.sample(clips, 2))]

    scored = all(c["score"] is not None for c in clips)
    if len(decided) >= ACTIVE_AFTER and scored and rng.random() > RANDOM_RATE:
        def unsure(pair):  # 0 when the model thinks it's a coin flip
            p = 1 / (1 + math.exp(-(pair[0]["score"] - pair[1]["score"])))
            return abs(p - 0.5)
        a, b = min(options, key=unsure)
    else:
        a, b = min(options, key=lambda p: shown[p[0]["id"]] + shown[p[1]["id"]])

    return {"a": a["id"], "b": b["id"], "is_repeat": False}
