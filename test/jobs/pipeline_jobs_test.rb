require "test_helper"
require "stringio"

class PipelineJobsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FakeMlClient
    attr_reader :transcription_calls, :candidate_calls

    def initialize
      @transcription_calls = []
      @candidate_calls = []
    end

    def transcribe(payload, request_id:, idempotency_key:)
      @transcription_calls << [payload, request_id, idempotency_key]
      {
        "video_id" => payload.fetch("video_id"),
        "transcript_version" => payload.fetch("transcript_version"),
        "language" => "en",
        "segments" => [
          {
            "sequence" => 0,
            "start_ms" => 0,
            "end_ms" => 20_000,
            "text" => "A complete thought.",
            "words" => [],
            "is_sentence_boundary_start" => true,
            "is_sentence_boundary_end" => true
          }
        ]
      }
    end

    def generate_candidates(payload, request_id:, idempotency_key:)
      @candidate_calls << [payload, request_id, idempotency_key]
      {
        "video_id" => payload.fetch("video_id"),
        "generation_version" => payload.fetch("generation_version"),
        "candidates" => [
          {
            "sequence" => 0,
            "start_ms" => 0,
            "end_ms" => 20_000,
            "duration_ms" => 20_000,
            "transcript" => "A complete thought.",
            "source_segment_sequences" => [0]
          }
        ]
      }
    end
  end

  setup do
    ActiveJob::Base.queue_adapter = :test
    ActiveStorage::Current.url_options = { host: "example.test" }
    clear_enqueued_jobs
  end

  test "transcription atomically persists segments and enqueues candidate generation" do
    video = create_video(duration_ms: 60_000)
    video.source_media.attach(io: StringIO.new("media"), filename: "source.mp4", content_type: "video/mp4")
    run = video.processing_runs.create!(pipeline_version: video.pipeline_version, idempotency_key: "video/#{video.id}/run")
    fake = FakeMlClient.new

    TranscribeVideoJob.perform_now(video.id, run.id, client: fake)

    video.reload
    run.reload
    assert_equal "generating_candidates", video.status
    assert_equal "transcription_complete", run.current_stage
    assert_equal "running", run.status
    assert_equal 1, video.transcript_segments.count
    assert_enqueued_with(job: GenerateCandidatesJob, args: [video.id, run.id])
    assert_equal "video/#{video.id}/run/#{run.id}/transcription", fake.transcription_calls.first.last
  end

  test "transcription persists duration discovered by Active Storage analysis" do
    video = create_video
    video.source_media.attach(io: StringIO.new("media"), filename: "source.mp4", content_type: "video/mp4")
    video.source_media.blob.update!(metadata: { "identified" => true, "analyzed" => true, "duration" => 60.0 })
    run = video.processing_runs.create!(pipeline_version: video.pipeline_version, idempotency_key: "video/#{video.id}/duration")
    fake = FakeMlClient.new

    TranscribeVideoJob.perform_now(video.id, run.id, client: fake)

    assert_equal 60_000, video.reload.duration_ms
    assert_equal 60_000, fake.transcription_calls.first.first.fetch("duration_ms")
  end

  test "candidate generation persists candidates and stops at extracting_features" do
    video = create_video(duration_ms: 60_000)
    run = video.processing_runs.create!(pipeline_version: video.pipeline_version, idempotency_key: "video/#{video.id}/run")
    video.transcript_segments.create!(
      sequence: 0, start_ms: 0, end_ms: 20_000, text: "A complete thought.", words: [],
      is_sentence_boundary_start: true, is_sentence_boundary_end: true, transcript_version: "whisper-1"
    )
    fake = FakeMlClient.new

    GenerateCandidatesJob.perform_now(video.id, run.id, client: fake)

    video.reload
    run.reload
    assert_equal "extracting_features", video.status
    assert_equal "candidates_complete", run.current_stage
    assert_equal "running", run.status
    assert_equal 1, video.candidate_clips.count
    assert_empty enqueued_jobs
  end

  test "a malformed candidate response is terminal and visible" do
    video = create_video(duration_ms: 60_000)
    run = video.processing_runs.create!(pipeline_version: video.pipeline_version, idempotency_key: "video/#{video.id}/run")
    video.transcript_segments.create!(
      sequence: 0, start_ms: 0, end_ms: 20_000, text: "A complete thought.", words: [],
      is_sentence_boundary_start: true, is_sentence_boundary_end: true, transcript_version: "whisper-1"
    )
    bad_client = Object.new
    bad_client.define_singleton_method(:generate_candidates) { |*, **| { "video_id" => video.id.to_s, "generation_version" => "candidate-1", "candidates" => [{ "sequence" => 0 }] } }

    GenerateCandidatesJob.perform_now(video.id, run.id, client: bad_client)

    assert_equal "failed", video.reload.status
    assert_equal "failed", run.reload.status
    assert_equal "MALFORMED_RESPONSE", run.error_code
    assert_empty video.candidate_clips
  end

  test "a transcription retry resumes an unfinished transcribing stage" do
    video = create_video(duration_ms: 60_000)
    video.source_media.attach(io: StringIO.new("media"), filename: "source.mp4", content_type: "video/mp4")
    run = video.processing_runs.create!(
      pipeline_version: video.pipeline_version,
      idempotency_key: "video/#{video.id}/retry",
      status: "running",
      current_stage: "transcribing",
      attempt_count: 1
    )
    fake = FakeMlClient.new

    TranscribeVideoJob.perform_now(video.id, run.id, client: fake)

    assert_equal 1, fake.transcription_calls.size
    assert_equal 2, run.reload.attempt_count
    assert_equal "transcription_complete", run.current_stage
  end

  test "a candidate retry resumes an unfinished generation stage" do
    video = create_video(duration_ms: 60_000)
    run = video.processing_runs.create!(
      pipeline_version: video.pipeline_version,
      idempotency_key: "video/#{video.id}/candidate-retry",
      status: "running",
      current_stage: "generating_candidates",
      attempt_count: 1
    )
    video.transcript_segments.create!(
      sequence: 0, start_ms: 0, end_ms: 20_000, text: "A complete thought.", words: [],
      is_sentence_boundary_start: true, is_sentence_boundary_end: true, transcript_version: "whisper-1"
    )
    fake = FakeMlClient.new

    GenerateCandidatesJob.perform_now(video.id, run.id, client: fake)

    assert_equal 1, fake.candidate_calls.size
    assert_equal 2, run.reload.attempt_count
    assert_equal "candidates_complete", run.current_stage
  end
end
