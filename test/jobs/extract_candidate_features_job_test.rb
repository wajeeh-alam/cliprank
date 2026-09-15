require "test_helper"
require "stringio"

class ExtractCandidateFeaturesJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FakeFeatureClient
    attr_reader :calls

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
      @calls = []
    end

    def extract_features(payload, request_id:, idempotency_key:)
      @calls << [ payload, request_id, idempotency_key ]
      raise @error if @error

      @response || {
        "video_id" => payload.fetch("video_id"),
        "candidate_id" => payload.fetch("candidate_id"),
        "feature_version" => payload.fetch("feature_version"),
        "model_version" => "baseline-1",
        "prompt_version" => nil,
        "semantic" => {
          "hook_strength" => 0.88,
          "standalone_clarity" => 0.96,
          "information_density" => 0.91,
          "novelty" => 0.67,
          "emotional_intensity" => 0.52,
          "quotability" => 0.84,
          "payoff_strength" => 0.90,
          "story_completeness" => 0.89,
          "technical_depth" => 0.61,
          "call_to_action_presence" => 0.10,
          "topic" => "career",
          "content_type" => "career_advice",
          "hook_type" => "contrarian"
        },
        "audio" => {
          "words_per_minute" => 168.2,
          "average_audio_energy" => 0.62,
          "energy_variance" => 0.18,
          "energy_change_at_hook" => 0.21,
          "silence_ratio" => 0.03,
          "longest_pause_ms" => 820,
          "pause_frequency" => 0.07
        },
        "visual" => {
          "face_presence_ratio" => 0.80,
          "visual_motion" => 0.31,
          "scene_change_rate" => 0.04,
          "screen_recording_ratio" => 0.0,
          "camera_change_frequency" => 0.02,
          "sample_count" => 20
        },
        "structural" => {
          "time_to_main_point_ms" => 1400,
          "intro_length_ms" => 1200,
          "sentence_completeness" => 0.94,
          "hook_to_payoff_time_ms" => 22_400,
          "dead_air_start_ms" => 0,
          "dead_air_end_ms" => 2100
        },
        "capability_warnings" => []
      }
    end
  end

  setup do
    ActiveJob::Base.queue_adapter = :test
    ActiveStorage::Current.url_options = { host: "example.test" }
    clear_enqueued_jobs
  end

  test "persists one validated feature set atomically and advances the barrier" do
    with_env("ML_MIN_VALID_CANDIDATES", "1") do
      video, run, candidate = build_pipeline
      fake = FakeFeatureClient.new

      ExtractCandidateFeaturesJob.perform_now(video.id, run.id, candidate.id, client: fake)

      feature_set = candidate.reload.candidate_feature_sets.first
      assert_equal "features-1", feature_set.feature_version
      assert_equal "baseline-1", feature_set.model_version
      assert_equal "extracting_features", video.reload.status
      assert_equal "features_complete", run.reload.current_stage
      assert_equal "running", run.status
      assert_equal "analyzing", candidate.status
      assert_equal "video/#{video.id}/run/#{run.id}/features/candidate/#{candidate.id}", fake.calls.first.last
    end
  end

  test "is idempotent when the feature set already exists" do
    with_env("ML_MIN_VALID_CANDIDATES", "1") do
      video, run, candidate = build_pipeline
      fake = FakeFeatureClient.new

      ExtractCandidateFeaturesJob.perform_now(video.id, run.id, candidate.id, client: fake)
      ExtractCandidateFeaturesJob.perform_now(video.id, run.id, candidate.id, client: fake)

      assert_equal 1, fake.calls.size
      assert_equal 1, candidate.reload.candidate_feature_sets.where(feature_version: "features-1").count
    end
  end

  test "records a permanent failure on the candidate while siblings remain processable" do
    video, run, candidate = build_pipeline
    sibling = video.candidate_clips.create!(
      sequence: 1, start_ms: 20_000, end_ms: 40_000, duration_ms: 20_000,
      transcript: "A second thought.", generation_version: "candidate-1"
    )
    error = Ml::Client::PermanentError.new("invalid media", code: "INVALID_MEDIA", details: { "provider_request_id" => "provider-1" })
    fake = FakeFeatureClient.new(error: error)

    ExtractCandidateFeaturesJob.perform_now(video.id, run.id, candidate.id, client: fake)

    assert_equal "failed", candidate.reload.status
    assert_equal "INVALID_MEDIA", candidate.processing_error_code
    assert_equal "running", run.reload.status
    assert_not_equal "failed", video.reload.status
    assert_equal "pending", sibling.reload.status
    assert_equal candidate.id.to_s, run.error_details.fetch("feature_failures").first.fetch("candidate_id")
  end

  test "completes the fan-out when enough candidates succeed despite an isolated failure" do
    with_env("ML_MIN_VALID_CANDIDATES", "1") do
      video, run, candidate = build_pipeline
      sibling = add_sibling(video)

      ExtractCandidateFeaturesJob.perform_now(video.id, run.id, candidate.id, client: FakeFeatureClient.new)
      error = Ml::Client::PermanentError.new("invalid media", code: "INVALID_MEDIA")
      ExtractCandidateFeaturesJob.perform_now(video.id, run.id, sibling.id, client: FakeFeatureClient.new(error: error))

      assert_equal "features_complete", run.reload.current_stage
      assert_equal "running", run.status
      assert_equal "failed", sibling.reload.status
      assert_equal 1, candidate.candidate_feature_sets.where(feature_version: "features-1").count
    end
  end

  test "fails the run only after all candidates finish below the valid minimum" do
    with_env("ML_MIN_VALID_CANDIDATES", "2") do
      video, run, candidate = build_pipeline
      sibling = add_sibling(video)

      ExtractCandidateFeaturesJob.perform_now(video.id, run.id, candidate.id, client: FakeFeatureClient.new)
      assert_equal "running", run.reload.status

      error = Ml::Client::PermanentError.new("invalid media", code: "INVALID_MEDIA")
      ExtractCandidateFeaturesJob.perform_now(video.id, run.id, sibling.id, client: FakeFeatureClient.new(error: error))

      assert_equal "failed", run.reload.status
      assert_equal "INSUFFICIENT_VALID_CANDIDATES", run.error_code
      assert_equal 1, run.error_details.fetch("valid_candidate_count")
      assert_equal 2, run.error_details.fetch("required_candidate_count")
      assert_equal "failed", video.reload.status
    end
  end

  private

  def build_pipeline
    video = create_video(duration_ms: 60_000)
    video.source_media.attach(io: StringIO.new("media"), filename: "source.mp4", content_type: "video/mp4")
    run = video.processing_runs.create!(
      pipeline_version: video.pipeline_version,
      idempotency_key: "video/#{video.id}/features",
      status: "running",
      current_stage: "candidates_complete"
    )
    candidate = video.candidate_clips.create!(
      sequence: 0, start_ms: 0, end_ms: 20_000, duration_ms: 20_000,
      transcript: "A complete thought.", generation_version: "candidate-1"
    )
    video.transcript_segments.create!(
      sequence: 0, start_ms: 0, end_ms: 20_000, text: "A complete thought.", words: [],
      is_sentence_boundary_start: true, is_sentence_boundary_end: true, transcript_version: "whisper-1"
    )
    [ video, run, candidate ]
  end

  def add_sibling(video)
    candidate = video.candidate_clips.create!(
      sequence: 1, start_ms: 20_000, end_ms: 40_000, duration_ms: 20_000,
      transcript: "A second complete thought.", generation_version: "candidate-1"
    )
    video.transcript_segments.create!(
      sequence: 1, start_ms: 20_000, end_ms: 40_000, text: "A second complete thought.", words: [],
      is_sentence_boundary_start: true, is_sentence_boundary_end: true, transcript_version: "whisper-1"
    )
    candidate
  end

  def with_env(key, value)
    original = ENV[key]
    ENV[key] = value
    yield
  ensure
    original.nil? ? ENV.delete(key) : ENV[key] = original
  end
end
