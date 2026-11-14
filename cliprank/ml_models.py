"""Pretrained models, loaded the first time they're needed."""

import threading

import numpy as np

from cliprank import config
from cliprank.candidates import Word

_lock = threading.Lock()
_loaded = {}


def _load(name, make):
    with _lock:
        if name not in _loaded:
            _loaded[name] = make()
        return _loaded[name]


def transcribe(samples: np.ndarray) -> list[Word]:
    from faster_whisper import WhisperModel

    model = _load("whisper", lambda: WhisperModel(config.WHISPER_MODEL, device="cpu", compute_type="int8"))
    segments, _ = model.transcribe(samples, word_timestamps=True, vad_filter=True)
    return [Word(int(w.start * 1000), int(w.end * 1000), w.word) for s in segments for w in (s.words or [])]


def embed_text(texts: list[str]) -> np.ndarray:
    from sentence_transformers import SentenceTransformer

    model = _load("text", lambda: SentenceTransformer(config.TEXT_MODEL, device="cpu"))
    return model.encode([t or "(no speech)" for t in texts], normalize_embeddings=True)


def embed_images(paths) -> np.ndarray:
    from PIL import Image
    from sentence_transformers import SentenceTransformer

    model = _load("image", lambda: SentenceTransformer(config.IMAGE_MODEL, device="cpu"))
    return model.encode([Image.open(p).convert("RGB") for p in paths], normalize_embeddings=True)
