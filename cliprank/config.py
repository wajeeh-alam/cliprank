import os
from pathlib import Path

DATA_DIR = Path(os.environ.get("CLIPRANK_DATA", "data")).resolve()
UPLOADS = DATA_DIR / "uploads"
CLIPS = DATA_DIR / "clips"
FRAMES = DATA_DIR / "frames"
EMB = DATA_DIR / "emb"
MODELS = DATA_DIR / "models"
DB_PATH = DATA_DIR / "cliprank.db"

WHISPER_MODEL = os.environ.get("CLIPRANK_WHISPER", "small.en")
TEXT_MODEL = os.environ.get("CLIPRANK_TEXT_MODEL", "BAAI/bge-small-en-v1.5")
IMAGE_MODEL = os.environ.get("CLIPRANK_IMAGE_MODEL", "clip-ViT-B-32")

# Candidate clip lengths for "try things out" sessions.
CLIP_MIN_MS = int(os.environ.get("CLIPRANK_CLIP_MIN_MS", 8_000))
CLIP_MAX_MS = int(os.environ.get("CLIPRANK_CLIP_MAX_MS", 45_000))
# A pause this long between sentences is treated as the boundary between takes.
TAKE_GAP_MS = int(os.environ.get("CLIPRANK_TAKE_GAP_MS", 2_500))
MAX_CLIPS_PER_VIDEO = int(os.environ.get("CLIPRANK_MAX_CLIPS", 60))
# Library (already-posted) videos longer than this are cut to their opening.
LIBRARY_MAX_MS = 90_000

RETRAIN_EVERY = 20  # decisive swipes between automatic retrains
MIN_PAIRS_TO_TRAIN = 20


def ensure_dirs() -> None:
    for d in (UPLOADS, CLIPS, FRAMES, EMB, MODELS):
        d.mkdir(parents=True, exist_ok=True)
