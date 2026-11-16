import os
from pathlib import Path

DATA_DIR = Path(os.environ.get("CLIPRANK_DATA", "data")).resolve()
UPLOADS = DATA_DIR / "uploads"
CLIPS = DATA_DIR / "clips"
FRAMES = DATA_DIR / "frames"
EMB = DATA_DIR / "emb"
MODELS = DATA_DIR / "models"
DB_PATH = DATA_DIR / "cliprank.db"

WHISPER_MODEL = "small.en"
TEXT_MODEL = "BAAI/bge-small-en-v1.5"
IMAGE_MODEL = "clip-ViT-B-32"

CLIP_MIN_MS = 8_000
CLIP_MAX_MS = 45_000
TAKE_GAP_MS = 2_500          # a pause this long starts a new take
MAX_CLIPS_PER_VIDEO = 60
OLD_POST_MAX_MS = 90_000     # longer old posts only use their first 90 s

FEATURES_VERSION = 2         # bump when clip features change; old clips get recomputed on start

RETRAIN_EVERY = 20           # swipes
MIN_PAIRS_TO_TRAIN = 20


def make_dirs():
    for d in (UPLOADS, CLIPS, FRAMES, EMB, MODELS):
        d.mkdir(parents=True, exist_ok=True)
