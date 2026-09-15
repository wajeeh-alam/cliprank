# ClipRank

ClipRank is a Rails and Python foundation for turning long-form recordings into
ranked short-form clip recommendations. Rails owns product state, uploads, and
background orchestration; a stateless FastAPI service owns media/ML analysis
behind versioned JSON contracts.

The current foundation includes the Phase 1 architecture, Rails domain schema,
strict ML API contracts, deterministic candidate generation and ranking
baselines, and a containerized development stack. Upload UI, pipeline jobs,
transcription, media feature extraction, preview rendering, and export are the
next implementation stages.

## Architecture

- Rails 8.1, PostgreSQL, Active Storage, Hotwire, and Solid Queue
- Python 3.12, FastAPI, and Pydantic 2 under `services/ml`
- PostgreSQL-backed application and queue databases
- MinIO for local S3-compatible object storage
- FFmpeg in both application images for future media processing

See [docs/stage-1-architecture.md](docs/stage-1-architecture.md) for the data
model, job design, API examples, versioning rules, and Phase 1 checklist.

## Run locally with Docker

```sh
cp .env.example .env
docker compose up --build
```

Change the placeholder passwords and tokens in `.env` before starting. The
default endpoints are:

- Rails: <http://localhost:3000>
- FastAPI health: <http://localhost:8000/health>
- MinIO API: <http://localhost:9000>
- MinIO console: <http://localhost:9001>

Stop the stack with `docker compose down`. Add `-v` only when you also intend to
delete the local PostgreSQL and MinIO development data.

## Tests

Rails model tests require PostgreSQL:

```sh
RAILS_ENV=test bin/rails db:prepare
PARALLEL_WORKERS=1 bin/rails test test/models
```

ML service tests require Python 3.12 and the `dev` dependency group:

```sh
cd services/ml
python -m pip install -e '.[dev]'
pytest
```

The transcription and media feature endpoints currently return a typed
`UNSUPPORTED_OPERATION` response until real providers are configured. They do
not return placeholder transcripts or fabricated analytics.
