require "test_helper"

class MetricSnapshotTest < ActiveSupport::TestCase
  setup do
    video = create_video
    candidate = create_candidate(video: video)
    ranking_run = create_ranking_run(video: video, feature_version: "features-test")
    prediction = create_prediction(ranking_run: ranking_run, candidate_clip: candidate)
    @published_at = Time.zone.parse("2026-01-01 12:00:00")
    @publication = video.user.publications.create!(
      candidate_clip: candidate,
      ranking_prediction: prediction,
      platform: "instagram",
      platform_account_key: "ig-1",
      post_id: "post-1",
      published_at: @published_at,
      source: "manual"
    )
  end

  test "derives actual post age and only treats present in-tolerance views as mature" do
    mature = @publication.metric_snapshots.create!(
      observed_at: @published_at + 71.5.hours, views: 1200, source: "manual", raw_metrics: {}
    )
    missing = @publication.metric_snapshots.create!(
      observed_at: @published_at + 72.hours, views: nil, source: "manual", raw_metrics: {}
    )
    late = @publication.metric_snapshots.create!(
      observed_at: @published_at + 90.hours, views: 2500, source: "manual", raw_metrics: {}
    )

    assert_in_delta 71.5, mature.post_age_hours.to_f
    assert mature.mature?
    assert_not missing.mature?
    assert_not late.mature?
    assert_equal mature, @publication.selected_outcome_snapshot
  end

  test "uses an idempotent fingerprint for duplicate imports" do
    attributes = { observed_at: @published_at + 72.hours, views: 1200, source: "csv", raw_metrics: {} }
    first = @publication.metric_snapshots.create!(attributes)
    duplicate = @publication.metric_snapshots.new(attributes)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:import_fingerprint], "has already been taken"
    assert_predicate first.import_fingerprint, :present?
  end
end
