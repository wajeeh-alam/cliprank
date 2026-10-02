# Outcome-feedback ranker

ClipRank keeps the deterministic `heuristic-1` ranker and adds a supervised,
regularized linear outcome model. The model is not reinforcement learning or a
causal estimate. It predicts an account-normalized outcome among clips that
were actually published.

## Outcome policy

- A publication is linked to the exact immutable ranking prediction that led
  to it. Unposted candidates remain unlabeled.
- Metric snapshots are append-only. Missing metrics remain null.
- The outcome snapshot is the observation closest to 72 hours in the inclusive
  60–84 hour window. Ties select the earlier observation. Current lifetime
  metrics for older posts are not treated as historical 72-hour outcomes.
- The target is `log1p(views) - trailing baseline`. The baseline is the median
  of the account's latest 20 mature outcomes that were observable at the time
  of publication, after at least five account outcomes. For each historical
  post, snapshot selection is rerun as-of that publication time, so a closer
  snapshot observed later cannot retroactively replace an outcome that was
  already available. Cold accounts use the
  platform-wide trailing median available at publication time; the first
  platform observation uses zero log views and is marked as a cold start.
- Instagram and LinkedIn train separate models. The current LinkedIn collector
  exposes impressions rather than video views, so it preserves those in raw
  metrics and leaves `views` missing; LinkedIn rows need a genuine view value
  from an authorized or manual source before they can become labels.

## Training and evaluation

FastAPI validates and flattens the 32 logical features: 29 numeric values and
three categorical values. Numeric inputs use `StandardScaler`, categorical
inputs use one-hot encoding with unknown-category handling, and `Ridge` learns
the outcome weights.

Splits are chronological. A source-video group that crosses a split boundary
is purged so no recording can appear on both sides. Preprocessing is fit on the
training partition only. A training row is also purged unless its selected
outcome had already been observed when the held-out evaluation window began;
the code never falls back to training on held-out rows when that embargo leaves
too little data. Reports contain baseline and feedback Spearman
correlation, prediction MAE/RMSE, split sample counts, exclusions and the exact
publication/snapshot manifest.

Artifacts are deterministic JSON containing scaler statistics, category
vocabularies, coefficients and intercept. Rails stores the artifact and its
SHA-256 checksum; FastAPI refuses schema or checksum mismatches. No pickle is
loaded.

Demo publications are isolated from real training data. If any real
publications exist for a platform, demo rows are excluded; a demo-only model is
stored and displayed with a demo-data label.

New models start in `shadow`. The initial release gate requires at least 20
training examples, five validation examples, five final-test examples and a
positive Spearman delta in both held-out windows. A model that does not meet
the gate remains shadow-only. Activation is explicit, one model can be active
per platform/schema, and activating an older eligible model performs rollback.
`FEEDBACK_RANKING_ENABLED=false` is a global kill switch that forces the
baseline path without deleting or changing any model version.

At ranking time ClipRank logs baseline and feedback ranks. Shadow models never
change the selected rank. Active models may select the feedback order; missing,
invalid or mismatched artifacts fall back to `heuristic-1`. Signed feature
contributions are model contributions, not causal explanations.

## Collection and imports

Mark a ranked clip as published from its result card. If its platform account
is connected, Solid Queue schedules an authorized collection near 72 hours.
Manual entry and CSV import are also available on the Feedback dashboard.

CSV requires `post_id,observed_at,views` and optionally accepts `likes`,
`comments`, `shares`, `saves`, `average_watch_time_seconds`, and
`retention_rate`. Imports are idempotent using a canonical fingerprint.

Set `FEEDBACK_OPERATOR_EMAIL` in shared deployments to restrict train,
activation and rollback controls. If it is blank, any authenticated user may
operate models for local/demo use.
