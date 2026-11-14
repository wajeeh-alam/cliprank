"""Lazily loaded pretrained models (Whisper, text and image encoders)."""

import threading


import numpy as np

from cliprank import config
from cliprank.candidates import Word

_lock = threading.Lock()
_cache: dict[str, object] = {}


def _get(name: str, factory):
    with _lock:
        if name not in _cache:
            _cache[name] = factory()
        return _cache[name]


def transcribe(samples: np.ndarray) -> list[Word]:
    """Transcribe 16 kHz mono float32 audio (decoded by ffmpeg, not PyAV)."""
    from faster_whisper import WhisperModel

    model = _get("whisper", lambda: WhisperModel(config.WHISPER_MODEL, device="cpu", compute_type="int8"))
    segments, _ = model.transcribe(samples, word_timestamps=True, vad_filter=True)
    words: list[Word] = []
    for seg in segments:
        for w in seg.words or []:
            words.append(Word(int(w.start * 1000), int(w.end * 1000), w.word))
    return words


def embed_text(texts: list[str]) -> np.ndarray:
    from sentence_transformers import SentenceTransformer

    model = _get("text", lambda: SentenceTransformer(config.TEXT_MODEL, device="cpu"))
    texts = [t if t.strip() else "(no speech)" for t in texts]
    return np.asarray(model.encode(texts, normalize_embeddings=True), dtype=np.float32)


def embed_images(paths: list) -> np.ndarray:
    from PIL import Image
    from sentence_transformers import SentenceTransformer

    model = _get("image", lambda: SentenceTransformer(config.IMAGE_MODEL, device="cpu"))
    images = [Image.open(p).convert("RGB") for p in paths]
    return np.asarray(model.encode(images, normalize_embeddings=True), dtype=np.float32)
