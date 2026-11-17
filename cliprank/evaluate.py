"""`cliprank eval`: compare model variants on the swipes you already have.

Every variant is scored the same honest way: whole videos are hidden, the
model is trained without them, then it guesses your picks inside them.
"""

import math

import numpy as np

from cliprank import model
from cliprank.db import DB

WORDS = ("text", "hook_text", "screen_text")
VISUALS = ("vis", "hook_vis")

VARIANTS = [
    model.Variant("current (PCA 8)"),
    model.Variant("PCA 4", pca_dims=4),
    model.Variant("PCA 16", pca_dims=16),
    model.Variant("no PCA, stronger regularization", pca_dims=None, C=0.01),
    model.Variant("words only", blocks=WORDS, scalars=False),
    model.Variant("visuals only", blocks=VISUALS, scalars=False),
    model.Variant("simple numbers only", blocks=(), scalars=True),
    model.Variant("quick picks count more", fast_weight=True),
    model.Variant("skips count as ties", skips_as_ties=True),
]


def margin(acc, n):
    """Roughly how far off the accuracy could be by luck (95%)."""
    return 1.96 * math.sqrt(acc * (1 - acc) / n) if n else float("nan")


def pct(x):
    return "  –  " if x is None else f"{x * 100:4.0f}%"


def run(db: DB) -> None:
    data = model.load_data(db)
    rows = db.all("SELECT a_id, b_id, choice, decision_ms FROM swipes")
    rows = [r for r in rows if r["a_id"] in data.idx and r["b_id"] in data.idx]
    decided = [r for r in rows if r["choice"] != "skip"]
    videos = {data.video_of[c] for r in rows for c in (r["a_id"], r["b_id"])}
    print(f"\n{len(decided)} picks and {len(rows) - len(decided)} skips, across {len(videos)} videos. "
          f"Old posts: {len(data.good)} good, {len(data.bad)} bad.")
    if not decided:
        print("Nothing to evaluate yet. Swipe first.\n")
        return

    # Active learning shows the closest-scored pairs, which are often two versions of one take.
    same = [r for r in rows if data.take_of[r["a_id"]] == data.take_of[r["b_id"]]]
    other = [r for r in rows if data.take_of[r["a_id"]] != data.take_of[r["b_id"]]]

    def describe(rs):
        times = [r["decision_ms"] for r in rs if r["choice"] != "skip" and r["decision_ms"]]
        skips = sum(r["choice"] == "skip" for r in rs) / len(rs)
        return f"{len(rs)} swipes, median {np.median(times) / 1000:.1f}s to decide, {skips:.0%} skipped" if times else f"{len(rs)} swipes"
    print(f"Two versions of the same take: {describe(same) if same else 'none'}")
    print(f"Different takes or videos:     {describe(other) if other else 'none'}")

    print(f"\n{'variant':34} {'new recordings':>16} {'new pairs':>10} {'old posts':>10}")
    for v in VARIANTS:
        tested = []
        _, m = model.evaluate(db, data, v, tested)
        if m is None:
            print("Not enough swipes yet (needs 20).\n")
            return
        acc, n = m["new_video_accuracy"], m["n_new_video_test_pairs"]
        nv = f"{pct(acc)} ±{margin(acc, n) * 100:2.0f}" if acc is not None else "  –  (1 video)"
        print(f"{v.name:34} {nv:>16} {pct(m['pair_accuracy']):>10} {pct(m['old_posts_auc']):>10}")
        if v == VARIANTS[0]:
            baseline, base_tested = m, tested

    print(f"\n{'longer clip wins':34} {pct(baseline['longer_wins']):>16}")
    print(f"{'your consistency on repeats':34} {pct(baseline['consistency']):>16}  ({baseline['n_repeats']} repeats)")

    if base_tested:
        same_take = [ok for p, ok in base_tested if data.take_of[p.a] == data.take_of[p.b]]
        diff_take = [ok for p, ok in base_tested if data.take_of[p.a] != data.take_of[p.b]]
        print("\nCurrent model on held-out videos, split by kind of pair:")
        for label, oks in (("same take (which version)", same_take), ("different takes (which idea)", diff_take)):
            if oks:
                print(f"  {label:32} {pct(float(np.mean(oks)))} of {len(oks)}")

    print("\nOnly trust a difference bigger than the ± next to it. "
          "'–' under new recordings means it needs swipes on 2+ videos.\n")
