require "test_helper"

class RankCandidatesJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FakeRankClient
    attr_reader :calls

    def initialize(response: nil)
      @response = response
      @calls = []
    end

    def rank(payload, request_id:, idempotency_key:)
      @calls << [ payload, request_id, idempotency_key ]
      return @response.call(payload) if @response.respond_to?(:call)

      ids = payload.fetch("candidates").map { |candidate| candidate.fetch("candidate_id") }
      {
        "video_id" => payload.fetch("video_id"),
        "feature_version" => payload.fetch("feature_version"),
        "scorer_version" => payload.fetch("scorer_version"),
        "ranked_candidates" => ids.each_with_index.map do |candidate_id, index|
          {
            "candidate_id" => candidate_id,
            "rank" => index + 1,
            "clip_score" => 90.0 - index,
            "components" => {
              "content_quality" => 92.0,
              "hook" => 88.0,
              "delivery" => 84.0,
              "pacing" => 90.0,
              "visual_engagement" => 78.0,
              "standalone_clarity" => 96.0
            },
            "component_details" => {
              "semantic" => { "weight" => 0.35, "normalized" => 0.9 },
              "hook" => { "weight" => 0.20, "normalized" => 0.88 },
              "structural" => { "weight" => 0.20, "normalized" => 0.90 },
              "delivery" => { "weight" => 0.15, "normalized" => 0.84 },
              "visual" => { "weight" => 0.10, "normalized" => 0.78 }
            }
          }
        end
      }
    end
  end

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  test "creates a frozen ranking snapshot and atomically persists scores" do
    with_env("ML_MIN_VALID_CANDIDATES", "2") do
      video, run, candidates = build_rankable_pipeline
      fake = FakeRankClient.new

      RankCandidatesJob.perform_now(video.id, run.id, client: fake)

      ranking_run = video.reload.ranking_runs.first
      assert_equal "features-1", ranking_run.feature_version
      assert_equal "heuristic-1", ranking_run.scorer_version
      assert_equal run, ranking_run.processing_run
      assert_equal({ "semantic" => 0.35, "hook" => 0.2, "structural" => 0.2, "delivery" => 0.15, "visual" => 0.1 }, ranking_run.config.fetch("weights"))
      assert_equal "succeeded", ranking_run.status
      assert_equal 2, ranking_run.candidate_scores.count
      assert_equal [ "ranked", "ranked" ], candidates.map { |candidate| candidate.reload.status }
      assert_equal "ranking_complete", run.reload.current_stage
      assert_equal "running", run.status
      assert_equal "generating_previews", video.reload.status
      assert_equal "video/#{video.id}/run/#{run.id}/rank", fake.calls.first.last
      assert_empty enqueued_jobs
    end
  end

  test "duplicate delivery reuses the successful ranking run and scores" do
    with_env("ML_MIN_VALID_CANDIDATES", "1") do
      video, run, = build_rankable_pipeline(count: 1)
      fake = FakeRankClient.new

      RankCandidatesJob.perform_now(video.id, run.id, client: fake)
      RankCandidatesJob.perform_now(video.id, run.id, client: fake)

      assert_equal 1, fake.calls.size
      assert_equal 1, video.reload.ranking_runs.count
      assert_equal 1, CandidateScore.where(ranking_run_id: video.ranking_runs.first.id).count
    end
  end

  test "separate processing runs create separate ranking histories" do
    with_env("ML_MIN_VALID_CANDIDATES", "1") do
      video, first_run, = build_rankable_pipeline(count: 1)
      second_run = video.processing_runs.create!(
        pipeline_version: video.pipeline_version,
        idempotency_key: "video/#{video.id}/rank-again",
        status: "running",
        current_stage: "features_complete"
      )
      fake = FakeRankClient.new

      RankCandidatesJob.perform_now(video.id, first_run.id, client: fake)
      RankCandidatesJob.perform_now(video.id, second_run.id, client: fake)

      assert_equal 2, video.reload.ranking_runs.count
      assert_equal [ first_run.id, second_run.id ].sort, video.ranking_runs.pluck(:processing_run_id).sort
      assert_equal 2, fake.calls.size
    end
  end

  test "does not rank before the feature barrier" do
    video = create_video(duration_ms: 60_000)
    run = video.processing_runs.create!(
      pipeline_version: video.pipeline_version,
      idempotency_key: "video/#{video.id}/before-ranking",
      status: "running",
      current_stage: "extracting_features"
    )
    fake = FakeRankClient.new

    RankCandidatesJob.perform_now(video.id, run.id, client: fake)

    assert_empty fake.calls
    assert_empty video.reload.ranking_runs
    assert_equal "extracting_features", run.reload.current_stage
  end

  test "a malformed rank response fails the processing run visibly" do
    with_env("ML_MIN_VALID_CANDIDATES", "1") do
      video, run, candidates = build_rankable_pipeline(count: 1)
      fake = FakeRankClient.new(response: lambda do |payload|
        {
          "video_id" => payload.fetch("video_id"),
          "feature_version" => payload.fetch("feature_version"),
          "scorer_version" => payload.fetch("scorer_version"),
          "ranked_candidates" => []
        }
      end)

      RankCandidatesJob.perform_now(video.id, run.id, client: fake)

      assert_equal "failed", run.reload.status
      assert_equal "failed", video.reload.status
      assert_equal "MALFORMED_RESPONSE", run.error_code
      assert_equal "failed", video.reload.ranking_runs.first.status
      assert_empty candidates.first.reload.candidate_scores
    end
  end

  private

  def build_rankable_pipeline(count: 2)
    video = create_video(duration_ms: 120_000)
    run = video.processing_runs.create!(
      pipeline_version: video.pipeline_version,
      idempotency_key: "video/#{video.id}/rank",
      status: "running",
      current_stage: "features_complete"
    )
    candidates = count.times.map do |index|
      start_ms = index * 20_000
      candidate = video.candidate_clips.create!(
        sequence: index,
        start_ms: start_ms,
        end_ms: start_ms + 20_000,
        duration_ms: 20_000,
        transcript: "Thought #{index}.",
        generation_version: "candidate-1",
        status: "analyzing"
      )
      create_feature_set(candidate: candidate, feature_version: "features-1")
      candidate
    end
    [ video, run, candidates ]
  end

  def with_env(key, value)
    original = ENV[key]
    ENV[key] = value
    yield
  ensure
    original.nil? ? ENV.delete(key) : ENV[key] = original
  end
end
