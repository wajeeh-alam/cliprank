# ClipRank Stage 1 Architecture

Status: proposed architecture only. This document does not scaffold or implement the Rails application or Python service.

## 1. Scope and decisions

Stage 1 must make this loop reliable for one account:

```text
upload a 10-minute recording
  -> asynchronous processing
  -> timestamped transcript
  -> 10–40 candidate clips
  -> structured semantic/audio/visual/structural features
  -> transparent 0–100 ClipScore
  -> top five previews, explanations, and export
```

The Rails application is the system of record. The Python service is stateless and performs media/ML work behind versioned internal contracts. Rails never depends on free-form model output: all service responses are Pydantic-validated before persistence.

The Stage 1 ranker is generic and heuristic. It is not a probability of virality and does not use historical performance or personalized training. Historical posts, feedback, evaluation runs, and model metadata are represented in the data model so later phases do not require a rewrite, but those features are out of the Stage 1 execution path.

Conventions used throughout:

- PostgreSQL and Rails domain IDs are `bigint`; Active Storage keeps the standard Rails schema. API IDs are serialized as strings.
- All timestamps are UTC ISO-8601. Media offsets are integer milliseconds (`*_ms`), never floating-point seconds at a persistence/API boundary.
- Feature values are normalized to `0.0..1.0`; scores are `0.0..100.0`.
- Every analysis result carries `feature_version`, `model_version` where applicable, `scorer_version`, and `prompt_version` where applicable.
- A `request_id` is used for tracing; an `idempotency_key` identifies a retriable stage operation.

## 2. Proposed monorepo structure

```text
/
├── app/                                  # Rails 8 application (root)
│   ├── controllers/
│   ├── jobs/                             # Solid Queue jobs
│   ├── models/
│   ├── services/                         # Rails orchestration, ports, explainers
│   └── views/                            # Hotwire/Turbo creator UI
├── config/
│   ├── routes.rb
│   ├── storage.yml
│   └── ranking.yml                       # versioned default heuristic config
├── db/
│   ├── migrate/
│   └── seeds.rb
├── lib/
├── services/
│   └── ml/
│       ├── app/
│       │   ├── api/                      # FastAPI routes and Pydantic schemas
│       │   ├── domain/                   # version-neutral feature/value objects
│       │   ├── ports/                    # Transcriber, extractors, ranker interfaces
│       │   ├── use_cases/                # orchestration per API operation
│       │   └── adapters/                 # Whisper, FFmpeg, OpenCV, librosa, providers
│       ├── tests/
│       ├── pyproject.toml
│       └── Dockerfile
├── docs/
├── docker-compose.yml
├── Dockerfile                            # Rails web/worker image
├── Gemfile
├── Gemfile.lock
└── .env.example
```

The root remains a normal Rails application. `services/ml` has its own Python dependency lock and tests; it is not a Python monolith embedded in Rails. Shared contract examples may later live in `contracts/`, but Stage 1 keeps this architecture document as the source of truth until schemas are generated and checked in.

## 3. Rails data model

All tables have Rails `id`, `created_at`, and `updated_at` unless stated otherwise. Check constraints below should be database constraints, not only model validations. JSONB is reserved for evolving feature payloads and diagnostic details; core relationships and queryable values stay relational.

### Phase 1 tables

#### `users`

Rails authentication-owned account table. Minimum columns: `email` (unique, not null), authentication fields, and optional `name`. One user has many videos, historical posts, feedback events, and exports.

#### `videos`

| Column | Type / rule | Purpose |
|---|---|---|
| `user_id` | bigint, not null, FK | owner |
| `title` | varchar, not null | display title |
| `status` | enum/string, not null | `uploading`, `extracting_audio`, `transcribing`, `generating_candidates`, `extracting_features`, `ranking`, `generating_previews`, `complete`, `failed` |
| `duration_ms` | bigint, nullable, check `>= 0` | source duration |
| `source_media_checksum` | varchar, nullable | deduplication/audit hint |
| `processing_error_code` | varchar, nullable | terminal or latest error code |
| `processing_error_message` | text, nullable | user-safe error summary |
| `processing_error_details` | jsonb, not null default `{}` | provider/job diagnostics, redacted |
| `pipeline_version` | varchar, not null | pipeline contract/config version used |
| `completed_at` | timestamptz, nullable | completion marker |

Indexes: `(user_id, created_at DESC)`, `(user_id, status)`, and `source_media_checksum` (non-unique; the user may intentionally upload duplicates). The original recording is an Active Storage `has_one_attached :source_media`; generated preview/thumbnail files are attached to candidate clips.

#### `processing_runs`

One row represents one complete attempt at a pipeline version for a video. This is the durable idempotency and observability record.

| Column | Type / rule | Purpose |
|---|---|---|
| `video_id` | bigint, not null, FK | source video |
| `pipeline_version` | varchar, not null | e.g. `phase1-2026-09-01` |
| `idempotency_key` | varchar, not null, unique | stable key for the run |
| `status` | enum/string, not null | `pending`, `running`, `succeeded`, `failed` |
| `current_stage` | varchar, nullable | current pipeline stage |
| `attempt_count` | integer, not null default 0 | retry count |
| `error_code` | varchar, nullable | normalized failure code |
| `error_message` | text, nullable | safe summary |
| `error_details` | jsonb, not null default `{}` | sanitized diagnostics |
| `started_at`, `completed_at` | timestamptz, nullable | lifecycle timestamps |

Indexes: unique `(idempotency_key)` and `(video_id, pipeline_version, status)`; the latter supports finding an active run without preventing an explicit rerun with a new run key. A deliberate rerun uses a new idempotency key rather than silently overwriting results.

#### `transcript_segments`

| Column | Type / rule | Purpose |
|---|---|---|
| `video_id` | bigint, not null, FK | source video |
| `sequence` | integer, not null | source order |
| `start_ms`, `end_ms` | bigint, not null, checks `0 <= start_ms < end_ms` | segment interval |
| `text` | text, not null | segment text |
| `words` | jsonb, not null default `[]` | optional word timestamps: `{start_ms,end_ms,text}` |
| `is_sentence_boundary_start`, `is_sentence_boundary_end` | boolean, not null default false | candidate boundary hints |
| `transcript_version` | varchar, not null | provider/schema version |

Indexes: unique `(video_id, transcript_version, sequence)`, `(video_id, start_ms)`, and `(video_id, end_ms)`. The Rails callback/job rejects overlapping or out-of-order segments before replacing a transcript for a run.

#### `candidate_clips`

| Column | Type / rule | Purpose |
|---|---|---|
| `video_id` | bigint, not null, FK | source video |
| `sequence` | integer, not null | stable generation order |
| `start_ms`, `end_ms` | bigint, not null, checks `0 <= start_ms < end_ms` | detected boundaries |
| `duration_ms` | bigint, not null, check `15_000..60_000` for generated candidates | derived duration |
| `transcript` | text, not null | bounded candidate transcript snapshot |
| `status` | enum/string, not null | `pending`, `analyzing`, `ranked`, `rendering`, `ready`, `failed`, `rejected` |
| `generation_version` | varchar, not null | candidate algorithm version |
| `recommended_start_ms`, `recommended_end_ms` | bigint, nullable | suggested trim boundaries |
| `trim_reason` | text, nullable | explanation for suggested trim |
| `processing_error_code`, `processing_error_message` | varchar/text, nullable | candidate-local failure |

Indexes: `(video_id, sequence)`, `(video_id, status)`, `(video_id, start_ms)`, and `(video_id, end_ms)`. Unique `(video_id, generation_version, start_ms, end_ms)` prevents duplicate candidates on retry; overlaps are allowed by design. `duration_ms` is checked against the generated-candidate range, while manually adjusted preview boundaries are validated separately.

#### `candidate_feature_sets`

One candidate can have multiple immutable feature sets as algorithms evolve; exactly one set is selected by a ranking run.

| Column | Type / rule | Purpose |
|---|---|---|
| `candidate_clip_id` | bigint, not null, FK | candidate |
| `feature_version` | varchar, not null | schema/calculation version |
| `model_version` | varchar, nullable | semantic/vision/audio model version |
| `prompt_version` | varchar, nullable | only if a prompt-backed semantic adapter was used |
| `semantic_features` | jsonb, not null | normalized values + `topic`, `content_type`, `hook_type` |
| `audio_features` | jsonb, not null | measurable acoustic values and units |
| `visual_features` | jsonb, not null | sampled-frame values and sampling metadata |
| `structural_features` | jsonb, not null | timing/completeness values |
| `raw_metadata` | jsonb, not null default `{}` | non-user-facing provenance |

Unique `(candidate_clip_id, feature_version)`; index `(feature_version, created_at)`. Feature payloads must validate against the corresponding versioned schema before insert.

#### `ranking_runs`

| Column | Type / rule | Purpose |
|---|---|---|
| `video_id` | bigint, not null, FK | ranked video |
| `feature_version` | varchar, not null | input feature schema |
| `scorer_version` | varchar, not null | ranker implementation/config |
| `config` | jsonb, not null | frozen weights and normalization config |
| `status` | enum/string, not null | `pending`, `running`, `succeeded`, `failed` |
| `error_code`, `error_message` | varchar/text, nullable | failure details |
| `started_at`, `completed_at` | timestamptz, nullable | lifecycle |

Index `(video_id, created_at DESC)` and unique `(video_id, scorer_version, feature_version, created_at)` is not used; repeated explicit evaluation/reruns are valid. The latest successful run is selected by `completed_at`, never by mutable global state.

#### `candidate_scores`

Immutable result row for a candidate within a ranking run.

| Column | Type / rule | Purpose |
|---|---|---|
| `ranking_run_id`, `candidate_clip_id` | bigint, not null, FKs | score ownership |
| `rank` | integer, not null, check `>= 1` | ordered position |
| `clip_score` | numeric(5,2), not null, check `0..100` | overall recommendation score |
| `content_quality`, `hook`, `delivery`, `pacing`, `visual_engagement`, `standalone_clarity` | numeric(5,2), not null, checks `0..100` | independently displayable components |
| `component_details` | jsonb, not null default `{}` | feature contributions and penalties |

Unique `(ranking_run_id, candidate_clip_id)` and `(ranking_run_id, rank)`; index `(candidate_clip_id, created_at DESC)`. `clip_score` is explicitly a recommendation strength, not a virality probability.

#### `explanations`

| Column | Type / rule | Purpose |
|---|---|---|
| `candidate_score_id` | bigint, not null, FK | score being explained |
| `explanation_version` | varchar, not null | explanation template/schema |
| `summary` | text, not null | concise explanation |
| `strengths`, `weaknesses` | jsonb arrays, not null | user-facing bullets |
| `quantitative_facts` | jsonb array, not null | facts with `metric`, `value`, `unit`, `source_feature_path` |
| `model_version`, `prompt_version` | varchar, nullable | provenance if semantic text generation is added |

Unique `(candidate_score_id, explanation_version)`. Stage 1 may use a deterministic Rails template; any numeric fact must be copied from validated feature/score data, never invented by a language model.

#### `exports`

| Column | Type / rule | Purpose |
|---|---|---|
| `candidate_clip_id`, `user_id` | bigint, not null, FKs | exported candidate and owner |
| `start_ms`, `end_ms` | bigint, not null | exact exported boundaries |
| `status` | enum/string, not null | `requested`, `rendering`, `ready`, `failed` |
| `error_code`, `error_message` | varchar/text, nullable | export failure |
| `export_version` | varchar, not null | FFmpeg/export settings |

Index `(user_id, created_at DESC)` and `(candidate_clip_id, created_at DESC)`. The rendered file is an Active Storage attachment. A unique request key on the export job prevents duplicate renders.

### Future-phase tables (modeled, not in the Stage 1 execution path)

`historical_posts(user_id, platform, external_id, posted_at, duration_ms, transcript, source_video_id, feature_version, extracted_features)`, `post_metrics(historical_post_id, captured_at, views, likes, comments, shares, saves, average_watch_time_ms, completion_rate, normalized_performance, normalization_version)`, `feedback_events(user_id, candidate_clip_id, event_type, occurred_at, metadata)`, `evaluation_runs(scorer_version, feature_version, dataset_version, metrics, status)`, and `evaluation_results(evaluation_run_id, source_video_id, candidate_clip_id, label, rank, metrics)`. Add unique external IDs and indexes by user/time. These tables support Content DNA, normalization, labels, and offline comparison without presenting unsupported personalized insights in Phase 1.

Relationship summary: `users has_many videos`; `videos belongs_to users` and has many `processing_runs`, `transcript_segments`, `candidate_clips`, and `ranking_runs`; `candidate_clips belongs_to videos` and has many `candidate_feature_sets`, `candidate_scores` (through ranking runs), `explanations` (through scores), `exports`, and future `feedback_events`; `ranking_runs belongs_to videos` and has many `candidate_scores`; `candidate_scores belongs_to ranking_runs and candidate_clips` and has one or more versioned `explanations`; `historical_posts belongs_to users` and optionally a source `video`; `post_metrics belongs_to historical_posts`; and `evaluation_results belongs_to evaluation_runs`. Foreign keys are non-null for required relationships and restrict deletion of a video with persisted processing/results; user-initiated deletion should be an explicit retention workflow that removes attachments and dependent rows.

## 4. Solid Queue pipeline and failure semantics

The upload request only creates the video, Active Storage attachment, and a `processing_run`; it enqueues `TranscribeVideoJob` after commit. Every following job is enqueued only after the prior stage transaction commits.

```text
TranscribeVideoJob
  -> GenerateCandidatesJob
  -> ExtractCandidateFeaturesJob (one job per candidate, bounded fan-out)
  -> RankCandidatesJob
  -> RenderTopCandidatesJob (top five only)
  -> MarkVideoCompleteJob / UI refresh
```

The Rails-visible video status maps to those stages: `extracting_audio` is entered while the ML transcription operation prepares audio, `transcribing` while transcription runs, then `generating_candidates`, `extracting_features`, `ranking`, `generating_previews`, and `complete`.

Idempotency rules:

1. The parent passes `video_id`, `processing_run_id`, and a deterministic stage key such as `video/123/run/456/features/candidate/789`.
2. Each job takes a row lock on the processing run and exits successfully if its stage output is already committed. It will not regress a later stage.
3. Stage writes use unique keys: transcript `(video, transcript_version, sequence)`, candidate `(video, generation_version, start_ms, end_ms)`, feature `(candidate, feature_version)`, score `(ranking_run, candidate)`, and export request key.
4. External calls include the same stage key as `Idempotency-Key`. A timeout can therefore be retried without duplicating a result.
5. A stage advances `processing_runs.current_stage` and `videos.status` in the same database transaction as its output. The next job is enqueued with `after_commit`.

Retries and errors:

- Transient failures (HTTP 408/429/5xx, temporary object-storage or provider errors) retry with exponential backoff and jitter, up to the stage limit.
- Permanent failures (invalid media, malformed contract, unsupported codec, impossible timestamps) are recorded immediately with normalized `error_code`, safe `error_message`, sanitized `error_details`, and provider request ID if available.
- Exhausted retries set the run and video to `failed`, preserve all completed earlier outputs, and expose a retry action that starts a new run key. No exception is swallowed.
- Candidate-level feature failures mark that candidate `failed`; the ranker requires a configured minimum number of valid candidates and otherwise fails the run with `INSUFFICIENT_VALID_CANDIDATES`. A single bad candidate must not silently disappear.
- Job execution metrics include stage duration, attempt count, response status, and correlation IDs. Do not persist raw media or secrets in error details.

## 5. Python service architecture

The service is a stateless FastAPI process. It does not own user accounts or canonical results and does not write directly to PostgreSQL. It fetches a short-lived signed source-media URL supplied by Rails, uses temporary local storage, and returns validated JSON.

Request flow:

```text
FastAPI route + auth/request validation
  -> Pydantic 2 schema validation
  -> use case (transcribe / generate / extract / rank)
  -> domain ports
  -> provider adapters (FFmpeg, Whisper, OpenCV, librosa, semantic provider)
  -> normalized Pydantic response
```

Ports are explicit and replaceable:

- `Transcriber.transcribe(media: MediaRef) -> Transcript`
- `CandidateGenerator.generate(transcript, duration_ms, policy) -> CandidateSet`
- `SemanticFeatureExtractor.extract(candidate_transcript) -> SemanticFeatures`
- `AudioFeatureExtractor.extract(media, start_ms, end_ms) -> AudioFeatures`
- `VisualFeatureExtractor.extract(media, start_ms, end_ms, sampling_policy) -> VisualFeatures`
- `ClipRanker.rank(feature_sets, config) -> RankedCandidates`

The default adapters use FFmpeg for audio/frame extraction, a timestamp-capable Whisper adapter for transcription, deterministic NumPy/librosa calculations for audio, and OpenCV sampling for the initial visual measures. Semantic classification is behind an adapter and must emit the fixed enum values and normalized fields. A provider-specific response never crosses the API boundary.

Visual analysis is intentionally bounded and may return a `capability_warnings` array when an optional measure is unavailable. Phase 1 must still complete with the baseline feature set; advanced CV is not a blocker. The service enforces media-size/timeouts and never receives an unsigned public URL.

## 6. Versioned JSON API contracts

Base URL: internal `POST /internal/api/v1/...`. Requests require `Authorization: Bearer <service-token>`, `X-Request-Id`, and `Idempotency-Key`. JSON content type is required. A response may include a `warnings` array but never changes field meaning without a new contract version.

### Common envelope and error

Every successful response contains:

```json
{
  "contract_version": "1.0",
  "request_id": "req_01J...",
  "idempotency_key": "video/123/run/456/transcription",
  "data": {}
}
```

Every error contains:

```json
{
  "contract_version": "1.0",
  "request_id": "req_01J...",
  "error": {
    "code": "INVALID_MEDIA",
    "message": "The source media could not be decoded.",
    "retryable": false,
    "details": {"provider_request_id": "..."}
  }
}
```

The endpoint examples below show the contents of the successful response `data` member; the transport wraps each block in the common envelope.

### `POST /internal/api/v1/transcriptions`

Request:

```json
{
  "contract_version": "1.0",
  "video_id": "123",
  "media": {"signed_url": "https://storage.local/...", "mime_type": "video/mp4"},
  "duration_ms": 600000,
  "transcript_version": "whisper-1",
  "language": null
}
```

Response data:

```json
{
  "video_id": "123",
  "transcript_version": "whisper-1",
  "language": "en",
  "segments": [
    {
      "sequence": 0,
      "start_ms": 124200,
      "end_ms": 129800,
      "text": "I think the biggest mistake students make when applying...",
      "words": [
        {"start_ms": 124200, "end_ms": 124650, "text": "I"}
      ],
      "is_sentence_boundary_start": true,
      "is_sentence_boundary_end": true
    }
  ]
}
```

### `POST /internal/api/v1/candidates/generate`

Request:

```json
{
  "contract_version": "1.0",
  "video_id": "123",
  "duration_ms": 600000,
  "generation_version": "candidate-1",
  "min_duration_ms": 15000,
  "max_duration_ms": 60000,
  "target_count_min": 10,
  "target_count_max": 40,
  "segments": [
    {"sequence": 0, "start_ms": 124200, "end_ms": 129800, "text": "...", "is_sentence_boundary_start": true, "is_sentence_boundary_end": true}
  ]
}
```

Response data:

```json
{
  "video_id": "123",
  "generation_version": "candidate-1",
  "candidates": [
    {
      "sequence": 0,
      "start_ms": 134100,
      "end_ms": 174700,
      "duration_ms": 40600,
      "transcript": "Why most student projects aren't impressive...",
      "source_segment_sequences": [3, 4, 5]
    }
  ]
}
```

The service may return fewer than 10 candidates only when the source cannot support the policy; it returns a warning explaining why. Candidate intervals may overlap.

### `POST /internal/api/v1/candidates/features`

Request:

```json
{
  "contract_version": "1.0",
  "video_id": "123",
  "candidate_id": "789",
  "feature_version": "features-1",
  "media": {"signed_url": "https://storage.local/...", "mime_type": "video/mp4"},
  "start_ms": 134100,
  "end_ms": 174700,
  "transcript": "Why most student projects aren't impressive...",
  "transcript_segments": [{"start_ms": 134100, "end_ms": 140000, "text": "..."}]
}
```

Response data:

```json
{
  "video_id": "123",
  "candidate_id": "789",
  "feature_version": "features-1",
  "model_version": "semantic-baseline-1",
  "prompt_version": null,
  "semantic": {
    "hook_strength": 0.88,
    "standalone_clarity": 0.96,
    "information_density": 0.91,
    "novelty": 0.67,
    "emotional_intensity": 0.52,
    "quotability": 0.84,
    "payoff_strength": 0.90,
    "story_completeness": 0.89,
    "technical_depth": 0.61,
    "call_to_action_presence": 0.10,
    "topic": "career",
    "content_type": "career_advice",
    "hook_type": "contrarian"
  },
  "audio": {
    "words_per_minute": 168.2,
    "average_audio_energy": 0.62,
    "energy_variance": 0.18,
    "energy_change_at_hook": 0.21,
    "silence_ratio": 0.03,
    "longest_pause_ms": 820,
    "pause_frequency": 0.07
  },
  "visual": {
    "face_presence_ratio": 0.80,
    "visual_motion": 0.31,
    "scene_change_rate": 0.04,
    "screen_recording_ratio": 0.00,
    "camera_change_frequency": 0.02,
    "sample_count": 20
  },
  "structural": {
    "time_to_main_point_ms": 1400,
    "intro_length_ms": 1200,
    "sentence_completeness": 0.94,
    "hook_to_payoff_time_ms": 22400,
    "dead_air_start_ms": 0,
    "dead_air_end_ms": 2100
  },
  "capability_warnings": []
}
```

Numeric audio/visual/structural values are measured or derived from media/timestamps. They are not guessed by an LLM. Enum fields are rejected if unknown rather than persisted as arbitrary text.

### `POST /internal/api/v1/rank`

Request:

```json
{
  "contract_version": "1.0",
  "video_id": "123",
  "feature_version": "features-1",
  "scorer_version": "heuristic-1",
  "config": {
    "weights": {"semantic": 0.35, "hook": 0.20, "structural": 0.20, "delivery": 0.15, "visual": 0.10},
    "output_scale": 100
  },
  "candidates": [
    {"candidate_id": "789", "start_ms": 134100, "end_ms": 174700, "features": {"semantic": {}, "audio": {}, "visual": {}, "structural": {}}}
  ]
}
```

Response data:

```json
{
  "video_id": "123",
  "feature_version": "features-1",
  "scorer_version": "heuristic-1",
  "ranked_candidates": [
    {
      "candidate_id": "789",
      "rank": 1,
      "clip_score": 91.20,
      "components": {
        "content_quality": 94.00,
        "hook": 88.00,
        "delivery": 83.00,
        "pacing": 91.00,
        "visual_engagement": 78.00,
        "standalone_clarity": 96.00
      },
      "component_details": {
        "semantic": {"weight": 0.35, "normalized": 0.94},
        "hook": {"weight": 0.20, "normalized": 0.88},
        "structural": {"weight": 0.20, "normalized": 0.91},
        "delivery": {"weight": 0.15, "normalized": 0.83},
        "visual": {"weight": 0.10, "normalized": 0.78}
      }
    }
  ]
}
```

The scorer computes `clip_score = round(100 * (0.35*semantic + 0.20*hook + 0.20*structural + 0.15*delivery + 0.10*visual), 2)`. Component definitions and normalizations are versioned in `config`; the example values are illustrative, not fake analytics for a UI. Rails persists the returned components and config snapshot unchanged.

## 7. Phase 1 implementation checklist

1. Create the Rails 8 root app with PostgreSQL, Active Storage, Hotwire/Turbo, and Solid Queue configuration.
2. Add users, videos, processing runs, transcript segments, candidates, feature sets, ranking runs, scores, explanations, and exports migrations with the constraints/indexes above.
3. Add upload UI and create the video/run transaction; store the source in Active Storage and enqueue after commit.
4. Implement signed internal media URLs and the Rails ML client with request IDs, timeouts, schema validation, and idempotency keys.
5. Implement the Python `/internal/api/v1/transcriptions` contract with FFmpeg audio extraction and timestamped transcription.
6. Implement `/internal/api/v1/candidates/generate` using sentence/word boundaries, 15–60 second policy, overlap support, and 10–40 target count.
7. Implement `/internal/api/v1/candidates/features`: semantic schema validation, deterministic audio features, baseline OpenCV visual sampling, and structural features.
8. Implement `/internal/api/v1/rank` and freeze the initial `heuristic-1` config; keep every component accessible.
9. Implement the Solid Queue chain, bounded feature fan-out, retries, terminal error recording, and safe rerun behavior.
10. Implement deterministic explanations whose quantitative facts reference persisted feature paths.
11. Render previews/thumbnails only for top five after ranking; provide preview, export, and download actions.
12. Build a creator-focused results page with top three prominent, then remaining ranked candidates; show status and actionable errors.
13. Add tests for timestamp validation, candidate duration/boundaries, feature ranges, rank math, API schemas, idempotent jobs, retry classification, and top-five rendering.
14. Validate the acceptance path with a real 10-minute MP4: upload -> complete, at least five valid candidates, ranked results, explanations, and a playable/exportable preview.

Phase 1 explicitly excludes Instagram API integration, Content DNA, historical normalization, feedback UI, automatic speech rewriting, learned/personalized ranking, and rendering every candidate.

## 8. Dependencies

Rails:

- Ruby compatible with Rails 8, `rails`, `pg`, `solid_queue`, `active_storage`, `aws-sdk-s3`, and Hotwire/Turbo (`turbo-rails`, `stimulus-rails`).
- PostgreSQL 16+.
- FFmpeg available to the worker image for metadata, audio extraction, frame sampling, and preview rendering.

Python (`services/ml`):

- Python 3.12, FastAPI, Uvicorn, Pydantic 2, httpx, pytest.
- FFmpeg binary; `numpy` and `librosa` for deterministic audio measures; `opencv-python-headless` for frame sampling.
- A timestamp-capable Whisper adapter (initially `faster-whisper` or a configured transcription API). Provider selection must remain behind `Transcriber`.
- Optional semantic provider SDK only behind `SemanticFeatureExtractor`; no provider is allowed to define the contract.
- `scikit-learn` is optional for later evaluation/baselines and is not required by the Stage 1 heuristic ranker. XGBoost/LightGBM and PyTorch are deferred.

Development:

- Docker and Docker Compose, a local S3-compatible MinIO bucket, and environment variables for database, storage, service token, and optional transcription/semantic provider credentials.

## 9. Docker Compose and local setup plan

Compose services:

```text
db           PostgreSQL 16, named volume
storage      MinIO, named volume, S3 API on 9000 and console on 9001
ml           FastAPI/Uvicorn from services/ml, FFmpeg installed
web          Rails web server, depends on db/storage/ml
worker       Rails Solid Queue process, same image and dependencies as web
```

Solid Queue uses PostgreSQL as its queue/recurring storage; no Redis is required for Stage 1. `web` and `worker` share the Rails image but have separate commands and health checks. `ml` has a temporary working directory and no persistent application database. MinIO is development-only; production storage uses an S3-compatible bucket with the same Active Storage interface.

`.env.example` should define `DATABASE_URL`, Rails credentials/secret, `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `ML_BASE_URL`, `ML_SERVICE_TOKEN`, and optional model-provider variables. The Compose startup sequence is: start db/storage, create the bucket via a small init command, run Rails migrations, start `ml`, then start web and worker. A developer uploads through the Rails UI at localhost, while the worker calls the internal ML service over the Compose network and the browser only receives Rails-authorized results.

Production hardening deferred beyond this document includes private networking, secret management, resource quotas, malware scanning, object lifecycle policies, and a dedicated GPU worker if transcription volume requires it.

## 10. Internal consistency checks

- Every API media offset maps to a Rails `*_ms` column; no endpoint mixes seconds and milliseconds.
- The candidate generator's 15–60 second policy matches the `candidate_clips.duration_ms` check and the Phase 1 acceptance test.
- The rank request's `feature_version` and `scorer_version` map to `candidate_feature_sets` and `ranking_runs`; scores preserve both component columns and the frozen config.
- The top-five render job runs after a successful ranking run, so unused candidates are not rendered.
- Retry keys and unique database keys make repeated Solid Queue deliveries safe; errors are visible in both `processing_runs` and `videos`.
- Historical tables and feedback are future-phase data structures and cannot influence the Phase 1 generic score.
