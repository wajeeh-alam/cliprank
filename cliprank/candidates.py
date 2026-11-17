"""Cuts a long recording into clips using the transcript.

1. Words become sentences (split on . ? ! or a 0.7 s pause).
2. Sentences become takes (split on a pause of 2.5 s or more).
3. Inside a take, each sentence can start a clip. For each start we keep the
   shortest and longest clip that fits the length limits, so the same idea
   shows up with different openings and lengths.
4. Clips that overlap too much with a kept clip are dropped.
"""

from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Word:
    start_ms: int
    end_ms: int
    text: str


@dataclass(frozen=True)
class Span:
    start_ms: int
    end_ms: int
    text: str
    take: int = 0  # which take (stretch of talking between long pauses) it came from

    @property
    def duration_ms(self) -> int:
        return self.end_ms - self.start_ms


def sentences_from_words(words: list[Word], pause_ms: int = 700) -> list[Span]:
    out, cur = [], []
    for w in words:
        if cur and w.start_ms - cur[-1].end_ms >= pause_ms:
            out.append(_join(cur))
            cur = []
        cur.append(w)
        if w.text.strip().endswith((".", "?", "!")):
            out.append(_join(cur))
            cur = []
    if cur:
        out.append(_join(cur))
    return out


def _join(items) -> Span:
    return Span(items[0].start_ms, items[-1].end_ms, " ".join(i.text.strip() for i in items))


def split_takes(sentences: list[Span], gap_ms: int) -> list[list[Span]]:
    takes = []
    for s in sentences:
        if takes and s.start_ms - takes[-1][-1].end_ms < gap_ms:
            takes[-1].append(s)
        else:
            takes.append([s])
    return takes


def overlap(a: Span, b: Span) -> float:
    inter = max(0, min(a.end_ms, b.end_ms) - max(a.start_ms, b.start_ms))
    union = max(a.end_ms, b.end_ms) - min(a.start_ms, b.start_ms)
    return inter / union if union else 0.0


def make_clips(sentences, duration_ms, min_ms, max_ms, take_gap_ms, max_count, max_overlap=0.75) -> list[Span]:
    found = []
    for t, take in enumerate(split_takes(sentences, take_gap_ms)):
        if take[-1].end_ms - take[0].start_ms < min_ms:
            # Short take: keep it whole unless it's really short.
            if take[-1].end_ms - take[0].start_ms >= min_ms // 2:
                found.append(replace(_join(take), take=t))
            continue
        for i in range(len(take)):
            fits = [j for j in range(i, len(take)) if min_ms <= take[j].end_ms - take[i].start_ms <= max_ms]
            for j in {fits[0], fits[-1]} if fits else ():
                found.append(replace(_join(take[i:j + 1]), take=t))

    found.sort(key=lambda c: (-c.duration_ms, c.start_ms))  # longer clips win ties
    kept = []
    for c in found:
        if len(kept) < max_count and all(overlap(c, k) <= max_overlap for k in kept):
            kept.append(c)

    # A little padding so words aren't clipped at the edges.
    kept = [replace(c, start_ms=max(0, c.start_ms - 150), end_ms=min(duration_ms, c.end_ms + 350)) for c in kept]
    return sorted(kept, key=lambda c: c.start_ms)
