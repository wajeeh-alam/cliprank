"""Background worker that turns an uploaded video into clips with features.

video -> audio -> transcript -> clips -> (mp4, frames, embeddings) per clip
"""

import logging
import shutil
import threading
import time
import traceback

import numpy as np

from cliprank import config, media, ml_models
from cliprank.candidates import Span, make_clips, sentences_from_words
from cliprank.db import DB

log = logging.getLogger("cliprank")

# Order of the numbers in each clip's "scalars" array.
SCALARS = ["duration_s", "words_per_s", "first_word_delay_s", "loudness", "loudness_var", "silence"]
HOOK_WORDS = 12


def clip_path(cid):
    return config.CLIPS / f"{cid}.mp4"


def thumb_path(cid):
    return config.FRAMES / str(cid) / "0.jpg"


def emb_path(cid):
    return config.EMB / f"{cid}.npz"


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

        duration = media.duration_ms(src)
        self.db.run("UPDATE videos SET duration_ms = ? WHERE id = ?", (duration, vid))

        self._status(vid, "reading audio")
        samples = media.read_audio(src)

        self._status(vid, "transcribing")
        t = time.time()
        words = ml_models.transcribe(samples)
        log.info("video %s: %d words in %.0fs", vid, len(words), time.time() - t)

        if video["kind"] == "library":
            end = min(duration, config.OLD_POST_MAX_MS)
            spans = [Span(0, end, " ".join(w.text.strip() for w in words if w.start_ms < end))]
        else:
            spans = make_clips(sentences_from_words(words), duration, config.CLIP_MIN_MS, config.CLIP_MAX_MS,
                               config.TAKE_GAP_MS, config.MAX_CLIPS_PER_VIDEO)
            if not spans:
                raise RuntimeError("No clips found. Is there talking in this video?")

        for i, span in enumerate(spans, 1):
            self._status(vid, f"clip {i} of {len(spans)}")
            cid = self.db.run("INSERT INTO clips (video_id, start_ms, end_ms, text) VALUES (?, ?, ?, ?)",
                              (vid, span.start_ms, span.end_ms, span.text))
            media.cut(src, span.start_ms, span.end_ms, clip_path(cid))
            self.save_features(cid, span, words, samples)
            self.db.run("UPDATE clips SET ready = 1 WHERE id = ?", (cid,))

        self.db.run("UPDATE videos SET status = 'ready', progress = NULL WHERE id = ?", (vid,))

    def save_features(self, cid, span, words, samples):
        secs = span.duration_ms / 1000
        said = [w for w in words if span.start_ms <= w.start_ms < span.end_ms]

        # 3 frames from the first ~2 seconds (the hook) and 5 spread over the rest.
        hook_times = [t for t in (0.1, 1.0, 2.2) if t < secs]
        frames = media.frames(clip_path(cid), hook_times + [secs * f for f in (0.15, 0.35, 0.55, 0.75, 0.9)],
                              config.FRAMES / str(cid))
        images = ml_models.embed_images(frames)
        text, hook_text = ml_models.embed_text([span.text, " ".join(w.text.strip() for w in said[:HOOK_WORDS])])
        loud = media.loudness(samples, span.start_ms, span.end_ms)

        scalars = [
            secs,
            len(said) / max(secs, 0.1),
            (said[0].start_ms - span.start_ms) / 1000 if said else secs,
            loud["mean"], loud["var"], loud["silence"],
        ]
        np.savez(emb_path(cid), text=text, hook_text=hook_text, vis=images.mean(axis=0),
                 hook_vis=images[:max(1, len(hook_times))].mean(axis=0), scalars=np.array(scalars, dtype=np.float32))

    def delete_clips(self, vid):
        for row in self.db.all("SELECT id FROM clips WHERE video_id = ?", (vid,)):
            clip_path(row["id"]).unlink(missing_ok=True)
            emb_path(row["id"]).unlink(missing_ok=True)
            shutil.rmtree(config.FRAMES / str(row["id"]), ignore_errors=True)
        self.db.run("DELETE FROM clips WHERE video_id = ?", (vid,))
