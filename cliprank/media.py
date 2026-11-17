"""ffmpeg wrappers, plus simple measurements of the picture and the sound."""

import json
import subprocess
from pathlib import Path

import numpy as np

RATE = 16000  # Whisper wants 16 kHz mono
IMAGE_TYPES = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}


def _ffmpeg(*args) -> bytes:
    p = subprocess.run(["ffmpeg", "-y", "-v", "error", *args], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg: " + p.stderr.decode(errors="replace")[-500:])
    return p.stdout


def duration_ms(path: Path) -> int:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
                         capture_output=True, text=True, check=True).stdout
    return int(float(json.loads(out)["format"]["duration"]) * 1000)


def has_audio(path: Path) -> bool:
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                          "-of", "csv=p=0", str(path)], capture_output=True, text=True).stdout
    return bool(out.strip())


def read_audio(path: Path) -> np.ndarray:
    if not has_audio(path):  # some edits have no sound track
        return np.zeros(duration_ms(path) * RATE // 1000, dtype=np.float32)
    raw = _ffmpeg("-i", str(path), "-vn", "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-")
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768


def image_to_video(image: Path, out: Path, seconds: float = 5) -> None:
    """A photo post becomes a short still video so everything else treats it the same."""
    _ffmpeg("-loop", "1", "-i", str(image), "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
            "-t", str(seconds), "-vf", "scale='min(1080,iw)':-2,format=yuv420p", "-r", "30",
            "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", "-shortest", str(out))


def cut(src: Path, start_ms: int, end_ms: int, out: Path) -> None:
    # 720p H.264 so two clips can stream to a phone at once.
    _ffmpeg("-ss", f"{start_ms / 1000:.3f}", "-i", str(src), "-t", f"{(end_ms - start_ms) / 1000:.3f}",
            "-vf", "scale='if(gt(iw,ih),-2,720)':'if(gt(iw,ih),720,-2)'",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(out))


def export(src: Path, start_ms: int, end_ms: int, out: Path) -> None:
    """A clip at the original resolution and high quality, for posting."""
    _ffmpeg("-ss", f"{start_ms / 1000:.3f}", "-i", str(src), "-t", f"{(end_ms - start_ms) / 1000:.3f}",
            "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(out))


def frames(clip: Path, times_s: list[float], out_dir: Path) -> list[Path]:
    # 720 wide so captions are big enough to read.
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for i, t in enumerate(times_s):
        p = out_dir / f"{i}.jpg"
        _ffmpeg("-ss", f"{t:.3f}", "-i", str(clip), "-frames:v", "1", "-vf", "scale=720:-2", str(p))
        if p.exists():
            paths.append(p)
    return paths


def loudness(samples: np.ndarray) -> dict:
    hop = RATE // 50  # 20 ms chunks
    n = len(samples) // hop
    if n < 5 or np.abs(samples).max() < 1e-3:  # too short, or no sound at all
        return {"mean": 0.0, "var": 0.0, "silence": 1.0}
    rms = np.sqrt((samples[:n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    # "Silent" = more than 30 dB quieter than the loud parts of the clip.
    return {"mean": float(rms.mean()), "var": float(rms.std()), "silence": float((db < np.percentile(db, 95) - 30).mean())}


def beat(samples: np.ndarray) -> dict:
    """How strong a steady beat is (music has one, talking mostly doesn't) and its tempo."""
    hop = RATE // 100  # 10 ms
    n = len(samples) // hop
    if n < 300:  # under 3 s
        return {"beat": 0.0, "tempo": 0.0}
    energy = np.log((samples[:n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-8)
    onset = np.maximum(np.diff(energy), 0)  # moments where it suddenly gets louder
    onset -= onset.mean()
    ac = np.correlate(onset, onset, "full")[len(onset) - 1:]
    if ac[0] <= 0:
        return {"beat": 0.0, "tempo": 0.0}
    lags = np.arange(33, 101)  # 60-180 BPM, in 10 ms steps
    best = lags[np.argmax(ac[lags])]
    return {"beat": float(ac[best] / ac[0]), "tempo": 6000 / float(best)}


def motion(clip: Path) -> dict:
    """Cuts, movement and flashes, from tiny grayscale frames at 10 per second."""
    size = 32
    raw = _ffmpeg("-i", str(clip), "-an", "-vf", f"fps=10,scale={size}:{size},format=gray", "-f", "rawvideo", "-")
    f = np.frombuffer(raw, dtype=np.uint8).reshape(-1, size, size).astype(np.float32) / 255
    if len(f) < 3:
        return {"cuts_per_s": 0.0, "motion": 0.0, "flashes_per_s": 0.0}
    secs = len(f) / 10
    diff = np.abs(np.diff(f, axis=0)).mean(axis=(1, 2))  # how much the picture changed
    bright = np.abs(np.diff(f.mean(axis=(1, 2))))         # how much the brightness jumped
    return {
        "cuts_per_s": float((diff > 0.12).sum() / secs),
        "motion": float(np.median(diff)),
        "flashes_per_s": float((bright > 0.15).sum() / secs),
    }
