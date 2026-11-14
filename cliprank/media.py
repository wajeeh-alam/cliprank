"""FFmpeg helpers: probing, audio extraction, clip rendering, frames, audio stats."""

import json
import subprocess
import wave
from pathlib import Path

import numpy as np


def _run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed: {proc.stderr.strip()[-600:]}")
    return proc.stdout


def probe_duration_ms(path: Path) -> int:
    out = _run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)])
    return int(float(json.loads(out)["format"]["duration"]) * 1000)


def extract_audio(src: Path, wav: Path) -> None:
    _run(["ffmpeg", "-y", "-v", "error", "-i", str(src), "-vn", "-ac", "1", "-ar", "16000",
          "-c:a", "pcm_s16le", str(wav)])


def load_wav(wav: Path) -> np.ndarray:
    with wave.open(str(wav), "rb") as w:
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


# Shorter side becomes 720px: small enough to stream two at once on a phone.
_SCALE = "scale='if(gt(iw,ih),-2,720)':'if(gt(iw,ih),720,-2)'"


def render_clip(src: Path, start_ms: int, end_ms: int, out: Path) -> None:
    _run(["ffmpeg", "-y", "-v", "error", "-ss", f"{start_ms / 1000:.3f}", "-i", str(src),
          "-t", f"{(end_ms - start_ms) / 1000:.3f}", "-vf", _SCALE,
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p",
          "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(out)])


def extract_frames(clip: Path, times_s: list[float], out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for i, t in enumerate(times_s):
        p = out_dir / f"{i}.jpg"
        _run(["ffmpeg", "-y", "-v", "error", "-ss", f"{t:.3f}", "-i", str(clip),
              "-frames:v", "1", "-vf", "scale=336:-2", str(p)])
        if p.exists():
            paths.append(p)
    return paths


def audio_stats(samples: np.ndarray, start_ms: int, end_ms: int, sr: int = 16000) -> dict:
    seg = samples[int(start_ms * sr / 1000):int(end_ms * sr / 1000)]
    if seg.size < sr // 10:
        return {"rms_mean": 0.0, "rms_std": 0.0, "silence_ratio": 1.0}
    hop = sr // 50  # 20ms frames
    n = seg.size // hop
    rms = np.sqrt(np.mean(seg[: n * hop].reshape(n, hop) ** 2, axis=1) + 1e-12)
    db = 20 * np.log10(rms + 1e-9)
    silence = float(np.mean(db < (np.percentile(db, 95) - 30)))
    return {"rms_mean": float(rms.mean()), "rms_std": float(rms.std()), "silence_ratio": silence}
