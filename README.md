# ClipRank

I record a long video trying out different hooks and ideas, it gets chopped
into clips, and I pick the better of two clips on my phone. After a few hundred
picks it has a model of what I like, and I can check how well it guesses me on
clips it hasn't seen.

## Setup

You need ffmpeg and uv:

```bash
brew install ffmpeg uv
```

Start it on your computer:

```bash
uv run cliprank
```

It prints a QR code. Scan it with your phone (same Wi-Fi) and it logs you in.
The first upload is slow because it downloads the models (about 1 GB).

## Using it

1. **Upload** → New recording: a ~10 min video of you trying things.
2. **Upload** → Old posts: your posted videos, marked good or bad.
3. **Swipe**: tap a clip to hear it, then pick A or B. Skip if you can't decide.
4. **Stats**: check how it's doing. It retrains every 20 swipes.

## How it works

- **Cutting:** Whisper transcribes the video. Pauses of 2.5 s or more split it
  into takes. Inside a take, each sentence can start a clip (8–45 s).
- **Features per clip:** a text embedding of the whole transcript and of the
  first 12 words, a CLIP image embedding of the first 2 seconds and of the
  whole clip, plus length, words per second, time before the first word,
  loudness and silence.
- **Model:** each clip gets a score. The chance you pick A over B is
  `sigmoid(score A − score B)` (a Bradley-Terry model). It's fit with logistic
  regression on the difference between the two clips' features.
- **Picking pairs:** random at first. After 60 swipes it mostly shows pairs the
  model is unsure about, since those teach it the most.

Code: [`candidates.py`](cliprank/candidates.py) cuts clips,
[`pipeline.py`](cliprank/pipeline.py) processes uploads,
[`model.py`](cliprank/model.py) trains, [`pairs.py`](cliprank/pairs.py) picks
pairs, and [`server.py`](cliprank/server.py) is the web app.

Tests: `uv run pytest`
