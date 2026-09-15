# ClipRank

ClipRank turns long-form MP4/MOV recordings into timestamped short-form clip
candidates. Rails owns authentication, uploads, durable workflow state, and
persisted results. A stateless FastAPI service performs transcription,
candidate generation, and media feature extraction behind a versioned JSON
contract.

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

The current branch stops at `features_complete`. Transparent ranking, score
explanations, Top-5 results, and preview/export rendering are the next stages.

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

Endpoints:

- Rails: <http://localhost:3000>
- FastAPI health: <http://localhost:8000/health>
- MinIO API: <http://localhost:9000>
- MinIO console: <http://localhost:9001>

Useful runtime commands:

```sh
docker compose ps
docker compose logs -f worker ml
curl --fail http://localhost:8000/health
curl --fail http://localhost:3000/up
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

- Rails: 40 tests, 170 assertions, zero failures;
- Python: 21 tests, including real generated-media FFmpeg/OpenCV extraction;
- RuboCop: zero offenses in the feature-extraction changes;
- Brakeman: zero security warnings.

## End-to-end smoke test

1. Open <http://localhost:3000>, create an account, and upload a valid MP4/MOV
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
   puts({
     video_id: video&.id,
     video_status: video&.status,
     run_status: run&.status,
     stage: run&.current_stage,
     transcript_segments: video&.transcript_segments&.count,
     candidates: video&.candidate_clips&.count,
     feature_sets: features
   }.to_json)
   '
   ```

A successful run currently ends with `run_status: "running"`,
`stage: "features_complete"`, timestamped transcript segments, generated
candidates, and at least five feature sets. The video remains in
`extracting_features` until the ranking checkpoint is implemented.

## How the service boundary works

Rails sends authenticated internal requests containing `contract_version`, a
traceable request ID, and a stable idempotency key. FastAPI rejects unknown or
malformed fields with typed errors. It downloads only an approved signed media
URL, enforces byte/time/range limits, uses temporary storage, and deletes the
temporary files after each operation. Rails persists only validated results and
records sanitized candidate/run failures without storing signed URLs or tokens.
