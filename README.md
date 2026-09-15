# ClipRank

ClipRank turns long-form MP4/MOV recordings into timestamped short-form clip
candidates. Rails owns authentication, uploads, durable workflow state, and
persisted results. A stateless FastAPI service performs transcription,
candidate generation, media feature extraction, and transparent ranking behind
a versioned JSON contract.

## Integrated pipeline

```text
Upload in Rails
  -> Active Storage / MinIO
  -> Solid Queue TranscribeVideoJob
  -> FFmpeg + Faster Whisper timestamped transcript
  -> sentence-aligned 15-60 second candidate generation
  -> one ExtractCandidateFeaturesJob per candidate
  -> FFmpeg/OpenCV/transcript feature extraction
  -> concurrency-safe features_complete barrier
  -> RankCandidatesJob + versioned FastAPI heuristic scorer
  -> atomic RankingRun/CandidateScore persistence
  -> ranking_complete barrier
```

For every candidate, the service produces:

- 10 normalized semantic signals plus topic, content type, and hook type;
- 7 measured audio signals, including energy, silence, pauses, and pacing;
- 6 visual signals/metadata from bounded OpenCV frame sampling;
- 6 structural signals covering intros, payoff timing, completeness, and dead air.

Feature results carry `feature_version` and `model_version`. Rails validates the
response at the HTTP boundary and again before persistence. Unique database
keys, row locks, and deterministic idempotency keys make job retries safe.
Individual candidate failures remain isolated; the run advances only after all
candidates are terminal and at least five valid feature sets exist by default.

The current branch stops at `ranking_complete`. Deterministic score
explanations, Top-5 results, and preview/export rendering are the next stages;
no nonexistent preview job is enqueued at this checkpoint.

See [docs/stage-1-architecture.md](docs/stage-1-architecture.md) for the full
data model, contracts, and Phase 1 plan.

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

- Rails: 46 tests, 202 assertions, zero failures;
- Rails system smoke test: 1 test, 3 assertions, zero failures;
- Python: 26 passed and one optional real-media test skipped when FFmpeg is unavailable;
- RuboCop: zero offenses across 77 files;
- Brakeman: zero security warnings.
- Bundler and Importmap audits: no known vulnerable dependencies;
- redacted Gitleaks scan: no leaks across the branch history.

## End-to-end smoke test

1. Open <http://localhost:55050>, create an account, and upload a valid MP4/MOV
   containing spoken audio. A recording long enough to yield at least five
   coherent 15-60 second candidates is recommended.
2. Follow processing in another terminal:

   ```sh
   docker compose logs -f worker ml
   ```

3. Refresh the video page to see its durable stage and any safe error message.
4. Inspect the persisted pipeline output:

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
     top_scores: ranking&.candidate_scores&.order(:rank)&.limit(5)&.pluck(:rank, :clip_score)
   }.to_json)
   '
   ```

A successful run currently ends with `run_status: "running"`,
`stage: "ranking_complete"`, a succeeded ranking run, and one immutable score
per valid candidate. The video is marked `generating_previews` to expose the
next intended stage, but preview rendering is not implemented yet.

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

## How the service boundary works

Rails sends authenticated internal requests containing `contract_version`, a
traceable request ID, and a stable idempotency key. FastAPI rejects unknown or
malformed fields with typed errors. It downloads only an approved signed media
URL, enforces byte/time/range limits, uses temporary storage, and deletes the
temporary files after each operation. Rails persists only validated results and
records sanitized candidate/run failures without storing signed URLs or tokens.
