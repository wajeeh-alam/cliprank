"""Background worker: uploaded video -> transcript -> candidate clips -> features."""

import logging
import shutil
import threading
import time
import traceback

import numpy as np

from cliprank import config, media, ml_models
from cliprank.candidates import Window, generate_windows, sentences_from_words
from cliprank.db import DB

log = logging.getLogger("cliprank.pipeline")

SCALAR_NAMES = ["duration_s", "words_per_s", "first_word_delay_s", "rms_mean", "rms_std", "silence_ratio"]
HOOK_WORDS = 12


def clip_path(clip_id: int):
    return config.CLIPS / f"{clip_id}.mp4"


def thumb_path(clip_id: int):
    return config.FRAMES / str(clip_id) / "0.jpg"


def emb_path(clip_id: int):
    return config.EMB / f"{clip_id}.npz"


class Worker:
    def __init__(self, db: DB):
        self.db = db
        self.wake = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True, name="pipeline")

    def start(self):
        # Anything interrupted by a restart gets reprocessed from scratch.
        self.db.run("UPDATE videos SET status='queued', progress=NULL WHERE status='processing'")
        self.thread.start()

    def notify(self):
        self.wake.set()

    def _loop(self):
        while True:
            job = self.db.one("SELECT * FROM videos WHERE status='queued' ORDER BY id LIMIT 1")
            if not job:
                self.wake.wait(timeout=5)
                self.wake.clear()
                continue
            try:
                self.process(job)
            except Exception as exc:  # keep the worker alive; surface the error in the UI
                log.error("video %s failed:\n%s", job["id"], traceback.format_exc())
                self.db.run("UPDATE videos SET status='failed', error=? WHERE id=?", (str(exc)[:500], job["id"]))

    def _progress(self, vid: int, text: str):
        log.info("video %s: %s", vid, text)
        self.db.run("UPDATE videos SET progress=? WHERE id=?", (text, vid))

    def process(self, video: dict):
        vid = video["id"]
        src = config.UPLOADS / video["path"]
        self.db.run("UPDATE videos SET status='processing', error=NULL WHERE id=?", (vid,))
        self._clear_clips(vid)

        duration = media.probe_duration_ms(src)
        self.db.run("UPDATE videos SET duration_ms=? WHERE id=?", (duration, vid))

        self._progress(vid, "extracting audio")
        wav = config.UPLOADS / f"{vid}.wav"
        media.extract_audio(src, wav)
        samples = media.load_wav(wav)

        t0 = time.time()
        self._progress(vid, "transcribing")
        words = ml_models.transcribe(samples)
        log.info("video %s: %d words transcribed in %.1fs", vid, len(words), time.time() - t0)

        if video["kind"] == "library":
            end = min(duration, config.LIBRARY_MAX_MS)
            text = " ".join(w.text.strip() for w in words if w.start_ms < end)
            windows = [Window(0, end, text)]
        else:
            windows = generate_windows(
                sentences_from_words(words), duration, config.CLIP_MIN_MS, config.CLIP_MAX_MS,
                config.TAKE_GAP_MS, config.MAX_CLIPS_PER_VIDEO,
            )
            if not windows:
                raise RuntimeError("No speech-based clips found. Is there talking in this video?")

        clip_ids = []
        for i, w in enumerate(windows, 1):
            self._progress(vid, f"cutting clip {i}/{len(windows)}")
            cid = self.db.run("INSERT INTO clips (video_id, start_ms, end_ms, text) VALUES (?,?,?,?)",
                              (vid, w.start_ms, w.end_ms, w.text))
            media.render_clip(src, w.start_ms, w.end_ms, clip_path(cid))
            clip_ids.append((cid, w))

        self._progress(vid, "computing features")
        for cid, w in clip_ids:
            self._features(cid, w, words, samples)
            self.db.run("UPDATE clips SET ready=1 WHERE id=?", (cid,))

        wav.unlink(missing_ok=True)
        self.db.run("UPDATE videos SET status='ready', progress=? WHERE id=?",
                    (f"{len(clip_ids)} clips", vid))

    def _features(self, cid: int, w: Window, words, samples):
        dur_s = w.duration_ms / 1000
        clip_words = [x for x in words if w.start_ms <= x.start_ms < w.end_ms]
        hook_text = " ".join(x.text.strip() for x in clip_words[:HOOK_WORDS])
        first_delay = (clip_words[0].start_ms - w.start_ms) / 1000 if clip_words else dur_s

        # Spread frames across the clip, plus three dense frames in the first 3 s (the hook).
        hook_times = [t for t in (0.1, 1.0, 2.2) if t < dur_s]
        body_times = [dur_s * f for f in (0.15, 0.35, 0.55, 0.75, 0.9)]
        frames = media.extract_frames(clip_path(cid), hook_times + body_times, config.FRAMES / str(cid))
        img = ml_models.embed_images(frames)
        n_hook = min(len(hook_times), len(frames))
        txt = ml_models.embed_text([w.text, hook_text])
        a = media.audio_stats(samples, w.start_ms, w.end_ms)

        scalars = np.array([dur_s, len(clip_words) / max(dur_s, 0.1), first_delay,
                            a["rms_mean"], a["rms_std"], a["silence_ratio"]], dtype=np.float32)
        np.savez(emb_path(cid), text=txt[0], hook_text=txt[1], vis=img.mean(axis=0),
                 hook_vis=img[:max(n_hook, 1)].mean(axis=0), scalars=scalars)

    def _clear_clips(self, vid: int):
        for row in self.db.all("SELECT id FROM clips WHERE video_id=?", (vid,)):
            clip_path(row["id"]).unlink(missing_ok=True)
            emb_path(row["id"]).unlink(missing_ok=True)
            shutil.rmtree(config.FRAMES / str(row["id"]), ignore_errors=True)
        self.db.run("DELETE FROM clips WHERE video_id=?", (vid,))
