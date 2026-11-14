"""Split a long "trying things out" recording into candidate clips.

Words are grouped into sentences. A long pause marks the boundary between
takes, and no clip crosses it. Inside each take, every sentence can start a
clip, so you get alternative openings for the same material — which is exactly
what makes the swipes teach the model about hooks.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Word:
    start_ms: int
    end_ms: int
    text: str


@dataclass(frozen=True)
class Sentence:
    start_ms: int
    end_ms: int
    text: str


@dataclass(frozen=True)
class Window:
    start_ms: int
    end_ms: int
    text: str

    @property
    def duration_ms(self) -> int:
        return self.end_ms - self.start_ms


def sentences_from_words(words: list[Word], pause_ms: int = 700) -> list[Sentence]:
    out: list[Sentence] = []
    cur: list[Word] = []

    def flush():
        if cur:
            out.append(Sentence(cur[0].start_ms, cur[-1].end_ms, " ".join(w.text.strip() for w in cur).strip()))
            cur.clear()

    for i, w in enumerate(words):
        if cur and w.start_ms - cur[-1].end_ms >= pause_ms:
            flush()
        cur.append(w)
        if w.text.strip().endswith((".", "?", "!")):
            flush()
    flush()
    return out


def split_takes(sentences: list[Sentence], gap_ms: int) -> list[list[Sentence]]:
    takes: list[list[Sentence]] = []
    for s in sentences:
        if takes and s.start_ms - takes[-1][-1].end_ms < gap_ms:
            takes[-1].append(s)
        else:
            takes.append([s])
    return takes


def _iou(a: Window, b: Window) -> float:
    inter = max(0, min(a.end_ms, b.end_ms) - max(a.start_ms, b.start_ms))
    union = max(a.end_ms, b.end_ms) - min(a.start_ms, b.start_ms)
    return inter / union if union else 0.0


def generate_windows(
    sentences: list[Sentence],
    duration_ms: int,
    min_ms: int,
    max_ms: int,
    take_gap_ms: int,
    max_count: int,
    max_iou: float = 0.75,
    pad_start_ms: int = 150,
    pad_end_ms: int = 350,
) -> list[Window]:
    raw: list[Window] = []
    for take in split_takes(sentences, take_gap_ms):
        take_dur = take[-1].end_ms - take[0].start_ms
        if take_dur < min_ms:
            # A short complete take is still a legitimate attempt; keep it if it's not tiny.
            if take_dur >= min_ms // 2:
                raw.append(Window(take[0].start_ms, take[-1].end_ms, " ".join(s.text for s in take)))
            continue
        for i in range(len(take)):
            ends = [j for j in range(i, len(take)) if min_ms <= take[j].end_ms - take[i].start_ms <= max_ms]
            if not ends:
                continue
            # Shortest complete thought and longest that fits: two natural edits per opening.
            for j in {ends[0], ends[-1]}:
                raw.append(Window(take[i].start_ms, take[j].end_ms, " ".join(s.text for s in take[i:j + 1])))

    # Prefer longer, earlier-starting windows when overlap is too high.
    raw.sort(key=lambda w: (-w.duration_ms, w.start_ms))
    kept: list[Window] = []
    for w in raw:
        if all(_iou(w, k) <= max_iou for k in kept):
            kept.append(w)
        if len(kept) >= max_count:
            break

    padded = [
        Window(max(0, w.start_ms - pad_start_ms), min(duration_ms, w.end_ms + pad_end_ms), w.text)
        for w in kept
    ]
    return sorted(padded, key=lambda w: (w.start_ms, w.end_ms))
