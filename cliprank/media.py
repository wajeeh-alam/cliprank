"""ffmpeg wrappers."""

import json
import subprocess
from pathlib import Path

import numpy as np

RATE = 16000  # Whisper wants 16 kHz mono


def _ffmpeg(*args) -> bytes:
    p = subprocess.run(["ffmpeg", "-y", "-v", "error", *args], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg: " + p.stderr.decode(errors="replace")[-500:])
    return p.stdout


def duration_ms(path: Path) -> int:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
                         capture_output=True, text=True, check=True).stdout
    return int(float(json.loads(out)["format"]["duration"]) * 1000)


def read_audio(path: Path) -> np.ndarray:
    raw = _ffmpeg("-i", str(path), "-vn", "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-")
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768


def cut(src: Path, start_ms: int, end_ms: int, out: Path) -> None:
    # 720p H.264 so two clips can stream to a phone at once.
    _ffmpeg("-ss", f"{start_ms / 1000:.3f}", "-i", str(src), "-t", f"{(end_ms - start_ms) / 1000:.3f}",
            "-vf", "scale='if(gt(iw,ih),-2,720)':'if(gt(iw,ih),720,-2)'",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(out))


def frames(clip: Path, times_s: list[float], out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for i, t in enumerate(times_s):
        p = out_dir / f"{i}.jpg"
        _ffmpeg("-ss", f"{t:.3f}", "-i", str(clip), "-frames:v", "1", "-vf", "scale=336:-2", str(p))
        if p.exists():
            paths.append(p)
    return paths


def loudness(samples: np.ndarray, start_ms: int, end_ms: int) -> dict:
    seg = samples[start_ms * RATE // 1000:end_ms * RATE // 1000]
    hop = RATE // 50  # 20 ms chunks
    n = len(seg) // hop
    if n < 5:
        return {"mean": 0.0, "var": 0.0, "silence": 1.0}
    rms = np.sqrt((seg[:n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    # "Silent" = more than 30 dB quieter than the loud parts of the clip.
    return {"mean": float(rms.mean()), "var": float(rms.std()), "silence": float((db < np.percentile(db, 95) - 30).mean())}
