# ClipRank

Teach a model your own taste in short-form video by swiping on your phone.

1. **Record** one long take where you try things out: different hooks, retakes, new ideas.
2. **Upload** it from your phone. ClipRank cuts it into candidate clips at sentence and take boundaries. Every sentence in a take can start a clip, so you also get alternative openings of the same material.
3. **Swipe**: two clips at a time, pick the better one. After 60 swipes it switches to *active learning* and shows the pairs it's least sure about.
4. **Stats**: how well the model predicts your picks on swipes it never trained on, compared with dumb baselines and with your own consistency.

Your old posts can be uploaded and labelled good or bad. They're used two ways: as extra training pairs (good beats bad), and as a transfer test. *Does a model trained only on raw-clip swipes rank my good posts above my bad ones?*

## How it works

| Step | What happens |
|---|---|
| Transcribe | ffmpeg → 16 kHz audio → faster-whisper (`small.en`) with word timestamps |
| Cut | words → sentences → takes (a pause ≥ 2.5 s); 8–45 s windows inside each take; overlap-deduplicated |
| Features | transcript and first-12-words embeddings (`bge-small`); CLIP embeddings of 3 hook frames and 5 body frames; duration, speaking rate, time to first word, loudness, silence |
| Model | Bradley-Terry: `P(A beats B) = σ(w·x_A − w·x_B)`; logistic regression on feature differences, each embedding block PCA'd to 16 dims |
| Eval | 5-fold accuracy on unseen pairs, accuracy on fully unseen clips, a learning curve, "longer wins" / "faster talking wins" baselines, a self-consistency ceiling (5% of pairs are re-asked), and old-post AUC |

Everything runs locally on your computer. Nothing is uploaded anywhere else.

## Run it

Needs `ffmpeg` (`brew install ffmpeg`) and [`uv`](https://docs.astral.sh/uv/).

```bash
uv run cliprank
```

It prints a QR code. Scan it with your phone while on the same Wi-Fi, and add the page to your home screen. The first video takes a few extra minutes because the Whisper, text and image models download (about 1 GB in total).

Data lives in `./data/` (gitignored). `CLIPRANK_DATA=/some/path` moves it. `--port` changes the port.

```bash
uv run pytest
```

## Tips

- A 10-minute session gives roughly 30–60 clips, which is hundreds of possible pairs. Aim for 3+ sessions before taking the accuracy numbers seriously, and record different kinds of attempts in each.
- Tap a video to hear it (only one plays sound at a time). On a laptop: ← / → pick, ↓ both bad, space skip.
- If "unseen clips" accuracy sits well below "new pairs", the model is memorizing clips rather than learning taste. You need more variety, not more swipes.
