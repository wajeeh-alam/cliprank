"""Background worker that turns an uploaded video into clips with features.

New recording:  video -> transcript -> cut into clips at sentences -> features per clip
Whole video:    finished edits, old posts and photos stay as one clip (first 90 s)
"""

import logging
import shutil
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from cliprank import config, media, ml_models, model
from cliprank.candidates import Span, Word, make_clips, sentences_from_words
from cliprank.db import DB

log = logging.getLogger("cliprank")

# Order of the numbers in each clip's "scalars" array.
SCALARS = ["duration_s", "words_per_s", "first_word_delay_s", "loudness", "loudness_var", "silence",
           "beat", "tempo", "cuts_per_s", "motion", "flashes_per_s", "screen_words"]
HOOK_WORDS = 12
HOOK_TIMES = (0.1, 1.0, 2.2)  # seconds; frames that count as the hook


def clip_path(cid):
    return config.CLIPS / f"{cid}.mp4"


def thumb_path(cid):
    return config.FRAMES / str(cid) / "0.jpg"


def emb_path(cid):
    return config.EMB / f"{cid}.npz"


def unique(texts):
    """Join frame texts, skipping repeats (a caption usually stays on screen for many frames)."""
    seen, out = set(), []
    for t in texts:
        if t and t.lower() not in seen:
            seen.add(t.lower())
            out.append(t)
    return " / ".join(out)


class Worker:
    def __init__(self, db: DB, on_done=None):
        self.db = db
        self.on_done = on_done
        self.wake = threading.Event()

    def start(self):
        # Anything cut off by a restart starts over.
        self.db.run("UPDATE videos SET status = 'queued', progress = NULL WHERE status = 'processing'")
        threading.Thread(target=self._loop, daemon=True).start()

    def notify(self):
        self.wake.set()

    def _loop(self):
        try:
            self.fill_missing_takes()
            if self.update_old_clips() and self.on_done:
                self.on_done()
        except Exception:
            log.error("updating old clips failed:\n%s", traceback.format_exc())
        while True:
            video = self.db.one("SELECT * FROM videos WHERE status = 'queued' ORDER BY id LIMIT 1")
            if not video:
                self.wake.wait(timeout=5)
                self.wake.clear()
                continue
            try:
                self.process(video)
                if self.on_done:
                    self.on_done()
            except Exception as exc:
                log.error("video %s failed:\n%s", video["id"], traceback.format_exc())
                self.db.run("UPDATE videos SET status = 'failed', error = ? WHERE id = ?", (str(exc)[:500], video["id"]))

    def _status(self, vid, text):
        log.info("video %s: %s", vid, text)
        self.db.run("UPDATE videos SET progress = ? WHERE id = ?", (text, vid))

    def process(self, video):
        vid = video["id"]
        src = config.UPLOADS / video["path"]
        self.db.run("UPDATE videos SET status = 'processing', error = NULL WHERE id = ?", (vid,))
        self.delete_clips(vid)

        if src.suffix.lower() in media.IMAGE_TYPES:
            still = src.with_suffix(".mp4")
            media.image_to_video(src, still)
            src = still

        duration = media.duration_ms(src)
        self.db.run("UPDATE videos SET duration_ms = ? WHERE id = ?", (duration, vid))

        self._status(vid, "transcribing")
        t = time.time()
        words = ml_models.transcribe(media.read_audio(src))
        log.info("video %s: %d words in %.0fs", vid, len(words), time.time() - t)

        whole = Span(0, min(duration, config.OLD_POST_MAX_MS), "")
        if video["kind"] == "session":
            spans = make_clips(sentences_from_words(words), duration, config.CLIP_MIN_MS, config.CLIP_MAX_MS,
                               config.TAKE_GAP_MS, config.MAX_CLIPS_PER_VIDEO)
            if not spans:
                if duration > config.OLD_POST_MAX_MS:
                    raise RuntimeError("Not enough talking to cut this into clips. "
                                       "For music edits, upload with 'Keep each video whole'.")
                spans = [whole]
        else:
            spans = [whole]

        todo = []
        for span in spans:
            said = [Word(w.start_ms - span.start_ms, w.end_ms - span.start_ms, w.text)
                    for w in words if span.start_ms <= w.start_ms < span.end_ms]
            text = span.text or " ".join(w.text.strip() for w in said)
            cid = self.db.run("INSERT INTO clips (video_id, start_ms, end_ms, text, take) VALUES (?, ?, ?, ?, ?)",
                              (vid, span.start_ms, span.end_ms, text, span.take))
            todo.append((cid, span, said))

        def make(item):
            cid, span, said = item
            media.cut(src, span.start_ms, span.end_ms, clip_path(cid))
            self.save_features(cid, said)
            self.db.run("UPDATE clips SET ready = 1 WHERE id = ?", (cid,))

        # A few clips at a time: most of the work is ffmpeg, which runs in its own process.
        with ThreadPoolExecutor(config.CLIP_WORKERS) as pool:
            for i, _ in enumerate(pool.map(make, todo), 1):
                self._status(vid, f"clip {i} of {len(todo)}")

        # Score the new clips with the saved model right away, so they're ranked
        # (and active learning can use them) before the next retrain.
        tm = model.load_latest(self.db)
        if tm:
            ids = [r["id"] for r in self.db.all("SELECT id FROM clips WHERE video_id = ? ORDER BY id", (vid,))]
            for cid, s in zip(ids, tm.score(model.load_features(ids))):
                self.db.run("UPDATE clips SET score = ? WHERE id = ?", (float(s), cid))

        # Only now can its clips be swiped on. If processing restarts before
        # this line, the clips get deleted and remade, and no swipes are lost.
        self.db.run("UPDATE videos SET status = 'ready', progress = NULL WHERE id = ?", (vid,))

    def save_features(self, cid, said: list[Word]):
        """Everything the model knows about a clip. `said` has word times relative to the clip start."""
        clip = clip_path(cid)
        samples = media.read_audio(clip)
        secs = len(samples) / media.RATE

        # 3 frames from the first ~2 seconds (the hook) and 5 spread over the rest.
        hook_times = [t for t in HOOK_TIMES if t < secs]
        frames = media.frames(clip, hook_times + [secs * f for f in (0.15, 0.35, 0.55, 0.75, 0.9)],
                              config.FRAMES / str(cid))
        n_hook = max(1, len(hook_times))
        images = ml_models.embed_images(frames)

        # Captions and meme text read off the same frames.
        on_screen = [ml_models.read_text(p) for p in frames]
        screen = unique(on_screen)
        spoken = " ".join(w.text.strip() for w in said)
        hook = " ".join([unique(on_screen[:n_hook])] + [w.text.strip() for w in said[:HOOK_WORDS]]).strip()
        text, hook_text, screen_text = ml_models.embed_text([spoken, hook, screen])

        loud, music, moves = media.loudness(samples), media.beat(samples), media.motion(clip)
        scalars = [
            secs,
            len(said) / max(secs, 0.1),
            said[0].start_ms / 1000 if said else secs,
            loud["mean"], loud["var"], loud["silence"],
            music["beat"], music["tempo"],
            moves["cuts_per_s"], moves["motion"], moves["flashes_per_s"],
            len(screen.split()),
        ]
        np.savez(emb_path(cid), version=config.FEATURES_VERSION, text=text, hook_text=hook_text, screen_text=screen_text,
                 vis=images.mean(axis=0), hook_vis=images[:n_hook].mean(axis=0),
                 scalars=np.array(scalars, dtype=np.float32), screen=screen)
        if screen and not spoken:  # so the swipe page has something to show under the clip
            self.db.run("UPDATE clips SET text = ? WHERE id = ? AND text = ''", (f"[on screen] {screen}", cid))

    def fill_missing_takes(self):
        """Clips made before takes were saved: group them by overlap (clips never cross takes)."""
        for v in self.db.all("SELECT DISTINCT video_id FROM clips WHERE take IS NULL"):
            take, end = -1, -1
            for c in self.db.all("SELECT id, start_ms, end_ms FROM clips WHERE video_id = ? ORDER BY start_ms",
                                 (v["video_id"],)):
                if c["start_ms"] >= end:
                    take += 1
                end = max(end, c["end_ms"])
                self.db.run("UPDATE clips SET take = ? WHERE id = ?", (take, c["id"]))

    def update_old_clips(self) -> int:
        """Recompute features for clips made by an older version. Keeps the clips and your swipes."""
        stale = []
        for row in self.db.all("SELECT id FROM clips WHERE ready = 1"):
            p = emb_path(row["id"])
            if clip_path(row["id"]).exists() and (not p.exists() or "version" not in np.load(p)
                                                   or int(np.load(p)["version"]) < config.FEATURES_VERSION):
                stale.append(row["id"])
        for i, cid in enumerate(stale, 1):
            log.info("updating features for old clip %d (%d of %d)", cid, i, len(stale))
            self.save_features(cid, ml_models.transcribe(media.read_audio(clip_path(cid))))
        return len(stale)

    def delete_clips(self, vid):
        for row in self.db.all("SELECT id FROM clips WHERE video_id = ?", (vid,)):
            clip_path(row["id"]).unlink(missing_ok=True)
            emb_path(row["id"]).unlink(missing_ok=True)
            shutil.rmtree(config.FRAMES / str(row["id"]), ignore_errors=True)
            (config.EXPORTS / f"{row['id']}.mp4").unlink(missing_ok=True)
        self.db.run("DELETE FROM clips WHERE video_id = ?", (vid,))
