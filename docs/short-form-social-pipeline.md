# Short-form, Instagram, and title pipeline

## What the app does

ClipRank turns a spoken video into a small set of distinct, explainable edits,
ranks them using measured transcript/audio/visual/structural signals, renders
private previews, and proposes evidence-backed titles. An optional Instagram
Professional connection imports the creator's own captions and available
performance metrics so suggestions can reflect patterns that are rising in
their history.

## Architecture

```text
Browser
  -> Rails 8.1 monolith
       -> PostgreSQL: users, workflow state, candidates, scores, social history,
          immutable title sets and evidence
       -> Solid Queue: transcription, feature, ranking, preview, Instagram sync,
          and title jobs
       -> Active Storage / MinIO: private source and preview media
       -> Instagram client: OAuth, owned media, available insights
       -> FastAPI ML boundary
            -> FFmpeg + Faster Whisper
            -> OpenCV/audio/transcript features
            -> deterministic candidate generation and ranking
```

Rails is the system of record. FastAPI is stateless and must return a strict,
versioned contract. Every background stage is idempotent or protected by a row
or advisory lock, and provider tokens never cross into the ML service.

## Candidate analysis

The processing run freezes a mode and generation version:

- `audit`: sources up to 60 seconds, candidates may be 3-60 seconds, and one
  distinct result is enough;
- `repurpose`: longer sources, candidates remain 15-60 seconds, with a target
  of 10-40 windows.

Candidates prefer complete sentence boundaries. Before ranking, a deterministic
family filter removes near-duplicates when temporal intersection-over-union is
at least 0.80, or containment is at least 0.92 with boundaries within three
seconds. The canonical member prefers complete sentence boundaries, then the
shorter edit and stable source order. Downstream ranking is scoped to the
generation version frozen on that processing run, so retries cannot mix stale
candidate sets.

## Instagram integration and security

The connector supports Instagram Professional Business and Creator accounts
through Instagram Login. OAuth uses a random, user-bound, ten-minute state.
Short-lived tokens are exchanged server-side; long-lived tokens are encrypted
with AES-256-GCM using a key derived from `SECRET_KEY_BASE`. Tokens are absent
from job arguments, serialized models, application logs, the browser, and the
ML contract.

Owned media sync is capped at 200 recent items, uses cursor pagination, keeps
network calls outside database transactions, and serializes persistence per
account. Media and daily metric snapshots are protected by unique constraints,
and disconnect cascades through imported history. The graph base URL is pinned
to `https://graph.instagram.com`.

OAuth requests `instagram_business_basic` for owned media and
`instagram_business_manage_insights` for media analytics. The authenticated
dashboard shows imported captions and baseline like/comment counts even when
Meta does not return a richer insight metric for a particular media type.

Meta does not expose a universal Instagram trends feed through this API. The
product therefore labels evidence honestly: `Transcript` or `Creator history`.
It never claims a creator-history pattern is a platform-wide trend.

## Title analysis

Title generation is a separate, non-blocking job after ranking. It creates
three deterministic 4-12 word ideas for each displayed candidate from the
transcript, meaningful semantic topic, and hook type. Generic classifier
fallbacks such as `other` are suppressed; transcript structure such as a stated
subject, test target, or explicit question takes precedence.

With at least five imported captioned posts, the analyzer:

1. compares recent caption-term frequency with the creator's older half;
2. ranks performance using engagement rate when audience metrics exist and a
   lower-confidence likes/comments percentile otherwise;
3. requires normalized term overlap with the current clip before using a
   creator-history term;
4. records sample size, source media IDs, cutoff time, feature version, and a
   SHA-256 history fingerprint.

Title artifacts are frozen by generator version. A version-aware row-lock claim
prevents duplicate queue work, concurrent workers serialize, transient lock
failures retry, and any title failure is recorded without changing the ranking
or preview result.

## Local test flow

```sh
cp .env.example .env
docker compose up --build -d
docker compose ps
curl --fail http://localhost:55050/up
curl --fail http://localhost:55051/health
```

Open <http://localhost:55050>, create an account, and upload a spoken MP4/MOV.
Use a new upload when retesting a previously failed run; failed runs are kept as
audit history rather than silently mutated.

For Instagram, populate the optional `META_INSTAGRAM_*` variables in the
ignored `.env`, restart the stack, open **Integrations**, connect a Business or
Creator account, and select **Sync now**. Standard access is sufficient for app
roles/test accounts; serving arbitrary customers requires Meta App Review and
the appropriate access level.

## Interview explanation

The central design choice is separating deterministic evidence from external
provider data. Clip selection and ranking remain reproducible even when
Instagram is unavailable. Social history enriches a separately versioned title
artifact, so a provider failure cannot corrupt core video processing. Database
constraints, frozen run provenance, idempotency keys, and locks make retries
safe across a distributed job pipeline.

Resume bullets (XYZ format; retain only metrics you can explain):

- Built a Rails/FastAPI short-form analysis pipeline that converts 3-second to
  long-form spoken videos into ranked, playable edits using 32 semantic, audio,
  visual, and structural signals, with 99 Rails tests and 512 assertions.
- Reduced redundant clip recommendations by clustering windows at 0.80 temporal
  IoU or 0.92 containment and selecting deterministic sentence-aligned
  canonical edits, preventing whole-video and slightly trimmed duplicates from
  occupying multiple result slots.
- Integrated Instagram Professional OAuth and bounded creator-history sync for
  up to 200 recent posts, encrypting long-lived tokens with AES-256-GCM and
  isolating credentials from job payloads, logs, browsers, and the ML service.
- Implemented versioned title recommendations that compare recent versus older
  creator caption patterns, normalize engagement evidence, require clip-topic
  relevance, and persist reproducible provenance while remaining failure-
  isolated from ranking and preview delivery.
