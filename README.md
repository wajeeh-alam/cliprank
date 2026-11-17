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

1. **Upload** → New videos:
   - *Cut into clips*: a long video of you talking and trying things. Pause 3 s between takes.
   - *Keep each one whole*: finished edits, music + caption videos, memes, photos.
2. **Upload** → Old posts: things you've posted (videos or photos), marked good or bad.
3. **Swipe**: tap a clip to hear it, then pick A or B. Skip if you can't decide.
4. **Stats**: check how it's doing. It retrains every 20 swipes.
5. **Results**: tap a recording on the Upload page. Its takes are ranked best
   first, each showing its best version (opening line and length) and the
   other versions. Download cuts it again from your original upload at full
   quality (the swipe clips are 720p).

To compare model choices on the swipes you already have:

```bash
uv run cliprank eval
```

It tests each variant the honest way (hides whole videos) and prints how
far off each number could be by luck, so you only trust real differences.

## How it works

- **Cutting:** Whisper transcribes the video. Pauses of 2.5 s or more split it
  into takes. Inside a take, each sentence can start a clip (8–45 s).
- **Features per clip:**
  - text embeddings of what's said, of the hook (first 12 words plus on-screen
    text in the first 2 s), and of all on-screen text (read with the Mac's
    built-in text recognition)
  - CLIP image embeddings of the first 2 seconds and of the whole clip
  - length, words per second, time before the first word, loudness, silence,
    beat strength and tempo (music), cuts per second, movement, flashes, and
    number of on-screen words
- **Checking it honestly:** "New recordings" accuracy hides whole videos, refits
  everything without them, then guesses picks inside them. Hiding single clips
  overstates it because clips from one take overlap and look alike. Repeated
  pairs stay on the same side of each split, and old posts together count as
  at most a quarter of your swipes.
- **Saved model:** each retrain saves the PCA, scaler and weights together
  (`data/models/`), so new clips are scored as soon as they're processed.
- **Updating:** when the features change, clips made earlier get recomputed on
  start. Your swipes are kept.
- **Model:** each clip gets a score. The chance you pick A over B is
  `sigmoid(score A − score B)` (a Bradley-Terry model). It's fit with logistic
  regression on the difference between the two clips' features.
- **Picking pairs:** random at first. After 60 swipes it mostly shows pairs the
  model is unsure about, since those teach it the most.

Code: [`candidates.py`](cliprank/candidates.py) cuts clips,
[`pipeline.py`](cliprank/pipeline.py) processes uploads,
[`model.py`](cliprank/model.py) trains,
[`evaluate.py`](cliprank/evaluate.py) compares variants, [`pairs.py`](cliprank/pairs.py) picks
pairs, and [`server.py`](cliprank/server.py) is the web app.

Tests: `uv run pytest`
