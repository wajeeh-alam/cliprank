# ClipRank

ClipRank analyzes MP4/MOV videos for short-form publishing. It audits an
existing 3-60 second short as one or a few useful edits, or repurposes a longer
recording into distinct 15-60 second candidates. Rails owns authentication,
uploads, durable workflow state, and
persisted results. A stateless FastAPI service performs transcription,
candidate generation, media feature extraction, and transparent ranking behind
a versioned JSON contract.

## Integrated pipeline

```text
Upload in Rails
  -> Active Storage / MinIO
  -> Solid Queue TranscribeVideoJob
  -> FFmpeg + Faster Whisper timestamped transcript
  -> mode-aware candidate generation (3-60 second audit / 15-60 second repurpose)
  -> temporal IoU + containment deduplication
  -> one ExtractCandidateFeaturesJob per candidate
  -> FFmpeg/OpenCV/transcript feature extraction
  -> concurrency-safe features_complete barrier
  -> RankCandidatesJob + versioned FastAPI heuristic scorer
  -> atomic RankingRun/CandidateScore persistence
  -> deterministic evidence-backed explanations
  -> versioned transcript/creator-history title ideas
  -> ranking_complete barrier
  -> RenderPreviewsJob + FFmpeg Top-5 MP4/JPEG generation
  -> versioned PreviewArtifact rows + private Active Storage files
  -> all-artifacts-ready completion barrier
  -> authenticated Top-5 playback UI
```

For every candidate, the service produces:

- 10 normalized semantic signals plus topic, content type, and hook type;
- 7 measured audio signals, including energy, silence, pauses, and pacing;
- 6 visual signals/metadata from bounded OpenCV frame sampling;
- 6 structural signals covering intros, payoff timing, completeness, and dead air.

Feature results carry `feature_version` and `model_version`. Rails validates the
response at the HTTP boundary and again before persistence. Unique database
keys, row locks, deterministic idempotency keys, and a ranking-run advisory
lock make job retries and duplicate preview deliveries safe.
Individual candidate failures remain isolated. Short-form audits can proceed
with one distinct edit; long-form runs require up to five valid feature sets,
capped by the number of genuinely distinct candidates the source supports.

The current branch produces an explainable, playable ranked set with title
ideas and optional Instagram creator-history evidence. Preview MP4s and
JPEG thumbnails are immutable, versioned artifacts scoped to one ranking run;
an older run cannot overwrite or serve media for the current result. Export is
the next isolated stage and is intentionally not exposed yet.

See [docs/stage-1-architecture.md](docs/stage-1-architecture.md) for the full
data model, contracts, and Phase 1 plan.
See [docs/short-form-social-pipeline.md](docs/short-form-social-pipeline.md) for
the current candidate, Instagram, and title-analysis architecture.

## Run locally with Docker

```sh
cp .env.example .env
docker compose up --build
```

Replace the development-only placeholder passwords, token, and Rails secret in
`.env` before starting. Initial startup builds both services. The first real
transcription also downloads the configured Whisper model into the persistent
`whisper_models` volume.

Conductor assigns this workspace ports beginning at `55050`. Set these
non-secret values in `.env` before starting so it can run beside other
workspaces:

```dotenv
COMPOSE_PROJECT_NAME=cliprank_davao
WEB_PORT=55050
ML_PORT=55051
POSTGRES_PORT=55052
S3_PORT=55053
MINIO_CONSOLE_PORT=55054
```

Keep the passwords, Rails secret, and ML service token in the ignored `.env`
file only. Never copy them into source, documentation, or CI configuration.

Instagram is optional. To connect a Professional Business or Creator account,
create a Meta app with Instagram Login, allow-list the callback URL, and set
the blank `META_INSTAGRAM_*` entries in `.env`. ClipRank requests only the
currently documented `instagram_business_basic` scope. Personal accounts are
not supported. See Meta's [official Instagram API workspace](https://www.postman.com/meta/instagram/overview).

Endpoints:

- Rails: <http://localhost:55050>
- FastAPI health: <http://localhost:55051/health>
- MinIO API: <http://localhost:55053>
- MinIO console: <http://localhost:55054>

Useful runtime commands:

```sh
docker compose ps
docker compose logs -f worker ml
curl --fail http://localhost:55051/health
curl --fail http://localhost:55050/up
```

Stop containers while retaining database, media, and model data:

```sh
docker compose down
```

Use `docker compose down -v` only when intentionally deleting all local
PostgreSQL, MinIO, and Whisper-cache volumes.

## Automated tests

Run the Rails suite against an isolated test database in the Compose PostgreSQL
service:

```sh
docker compose run --rm \
  -e RAILS_ENV=test \
  -e DATABASE_URL= \
  web sh -lc \
  'export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/cliprank_test"; bin/rails db:prepare test'
```

Run Rails linting and security checks:

```sh
docker compose run --rm web bin/rubocop
docker compose run --rm web bin/brakeman --no-pager
```

Run the Python suite locally with Python 3.12 and `uv`:

```sh
cd services/ml
uv run --python 3.12 --extra dev pytest -q
```

The real FFmpeg/OpenCV test is skipped when FFmpeg is unavailable on the host.
Run all Python tests inside the built ML image with:

```sh
docker compose build ml
docker run --rm \
  -v "$PWD/services/ml:/src" \
  -w /src \
  cliprank-ml sh -lc "pip install --no-cache-dir -e '.[dev]' && pytest -q"
```

Current verified results:

- Rails: 99 tests, 512 assertions, zero failures;
- Python: 32 passed and one optional real-media test skipped when FFmpeg is unavailable;
- RuboCop: zero offenses across 114 files;
- Brakeman: zero security warnings.
- Bundler and Importmap audits: no known vulnerable dependencies;
- redacted Gitleaks scan: no leaks across the branch history.

## End-to-end smoke test

1. Open <http://localhost:55050>, create an account, and upload a valid MP4/MOV
   containing spoken audio. A 3-60 second upload exercises short-form audit
   mode; a longer recording exercises repurposing mode.
2. Follow processing in another terminal:

   ```sh
   docker compose logs -f worker ml
   ```

3. Leave the video page open. It refreshes every 10 seconds while previews or
   title ideas are pending, then shows private playback, explanations, and
   three title ideas per ranked clip.
4. Play several clips and confirm each player's displayed timestamps match its
   ranked candidate. Opening another user's artifact route must return `404`.
5. Inspect the persisted pipeline output:

   ```sh
   docker compose exec web bin/rails runner '
   video = Video.order(:created_at).last
   run = video&.processing_runs&.order(:created_at)&.last
   features = video ? CandidateFeatureSet.joins(:candidate_clip).where(candidate_clips: { video_id: video.id }).count : 0
   ranking = run&.ranking_runs&.order(:created_at)&.last
   puts({
     video_id: video&.id,
     video_status: video&.status,
     run_status: run&.status,
     stage: run&.current_stage,
     transcript_segments: video&.transcript_segments&.count,
     candidates: video&.candidate_clips&.count,
     feature_sets: features,
     ranking_status: ranking&.status,
     scores: ranking&.candidate_scores&.count,
     top_scores: ranking&.candidate_scores&.order(:rank)&.limit(5)&.pluck(:rank, :clip_score),
     preview_artifacts: ranking&.preview_artifacts&.group(:kind, :status)&.count
   }.to_json)
   '
   ```

A successful run ends with `run_status: "succeeded"`, `stage: "complete"`, a
succeeded ranking run, one immutable score and one versioned explanation per
valid candidate, and two ready artifacts (MP4 preview plus JPEG thumbnail) for
each of the five highest-ranked results.

## Preview architecture and security

`RenderPreviewsJob` starts only after ranking persistence commits. The renderer
selects ranks 1-5, validates candidate bounds against the source duration, and
uses argument-array FFmpeg calls inside a permission-restricted temporary
directory. A PostgreSQL advisory lock serializes duplicate deliveries for the
same ranking run. Failed retries terminalize the run and its unfinished
artifacts; late jobs cannot mutate a completed or failed run.

Each `PreviewArtifact` records its ranking run, candidate, exact boundaries,
kind, render version, and status. The completion barrier reads only these
run-scoped artifacts, avoiding cross-run state corruption. Media remains
private in Active Storage/MinIO. The HTML contains authenticated Rails routes,
not blob keys or signed storage URLs; after verifying the signed-in owner,
current ranking, current render version, candidate ownership, and Top-5 rank,
Rails redirects to a five-minute service URL.

## How ranking analysis works

The scorer is deterministic and explainable rather than a black-box virality
prediction. It normalizes the 32 extracted signals into five aggregates and
computes recommendation strength as:

```text
ClipScore = 100 × (0.35 semantic + 0.20 hook + 0.20 structural
                   + 0.15 delivery + 0.10 visual)
```

The weights are frozen in `config/ranking.yml`; the score is bounded to
`0..100`, rounded to two decimals, and ties are ordered by candidate ID. Every
result preserves the scorer version, feature version, config snapshot, six
display components, and normalized component details. Rails rejects malformed,
cross-video, incomplete, duplicate, or non-contiguously ranked responses before
opening one transaction to persist the complete ranking.

Explanation generation runs inside that same transaction. It uses deterministic
threshold rules over the persisted feature set, records exact source paths for
every numeric fact, suppresses unavailable visual capabilities, and rolls back
the full ranking if any candidate cannot be explained. The results controller
also requires complete current-version explanations and candidate ownership
before rendering, preventing partial or cross-video results from appearing.

## How the service boundary works

Rails sends authenticated internal requests containing `contract_version`, a
traceable request ID, and a stable idempotency key. FastAPI rejects unknown or
malformed fields with typed errors. It downloads only an approved signed media
URL, enforces byte/time/range limits, uses temporary storage, and deletes the
temporary files after each operation. Rails persists only validated results and
records sanitized candidate/run failures without storing signed URLs or tokens.
