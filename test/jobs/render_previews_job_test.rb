require "test_helper"

class RenderPreviewsJobTest < ActiveSupport::TestCase
  class FakeRunner
    attr_reader :preview_calls, :thumbnail_calls, :probe_calls

    def initialize
      @preview_calls = []
      @thumbnail_calls = []
      @probe_calls = []
    end

    def probe(path)
      @probe_calls << path
      120.0
    end

    def render_preview(source, destination, start_seconds:, duration_seconds:)
      @preview_calls << [ source, start_seconds, duration_seconds ]
      File.binwrite(destination, "mp4")
    end

    def render_thumbnail(source, destination, at_seconds:)
      @thumbnail_calls << [ source, at_seconds ]
      File.binwrite(destination, "jpg")
    end
  end

  test "renders exactly the ranked Top 5 and completes the run" do
    video, run, ranking_run, candidates = build_ranked_video(6)
    runner = FakeRunner.new

    Previews::Renderer.call(ranking_run, runner: runner)

    assert_equal 5, runner.preview_calls.size
    assert_equal 5, runner.thumbnail_calls.size
    assert_equal 10, ranking_run.preview_artifacts.reload.size
    assert_equal 5, ranking_run.preview_artifacts.where(status: "ready").select(&:preview?).size
    assert_empty candidates.last.preview_artifacts
    assert_equal "succeeded", run.reload.status
    assert_equal "complete", run.current_stage
    assert_equal "complete", video.reload.status
    assert_equal [ 0.0, 20.0, 40.0, 60.0, 80.0 ], runner.preview_calls.map { |call| call[1] }
    assert_equal [ 20.0, 20.0, 20.0, 20.0, 20.0 ], runner.preview_calls.map { |call| call[2] }
  end

  test "is idempotent and does not invoke FFmpeg for ready artifacts" do
    _video, run, ranking_run, candidates = build_ranked_video(1)
    runner = FakeRunner.new

    Previews::Renderer.call(ranking_run, runner: runner)
    run.update!(status: "running", current_stage: "generating_previews", completed_at: nil)
    Previews::Renderer.call(ranking_run.reload, runner: runner)

    assert_equal 1, runner.preview_calls.size
    assert_equal 1, runner.thumbnail_calls.size
    assert_equal 2, ranking_run.preview_artifacts.count
    assert_equal "ranked", candidates.first.reload.status
    assert_equal "succeeded", run.reload.status
  end

  test "advisory lock permits only one renderer across database sessions" do
    lock_id = SecureRandom.random_number(1_000_000_000)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    connection_options = {
      dbname: config[:database],
      host: config[:host],
      port: config[:port],
      user: config[:username],
      password: config[:password]
    }.compact
    first_connection = PG.connect(connection_options)
    second_connection = PG.connect(connection_options)
    duplicate_result = nil

    rendered_result = Previews::Renderer::AdvisoryLock.synchronize(lock_id, connection: first_connection) do
      duplicate_result = Previews::Renderer::AdvisoryLock.synchronize(lock_id, connection: second_connection) do
        :duplicate
      end
      :rendered
    end

    assert_equal false, duplicate_result
    assert_equal :rendered, rendered_result
  ensure
    second_connection&.close
    first_connection&.close
  end

  test "persists a failed artifact and candidate when rendering fails" do
    video, run, ranking_run, candidates = build_ranked_video(1)
    runner = Class.new(FakeRunner) do
      def render_thumbnail(*); raise Previews::Renderer::PermanentError.new("bad media", code: "PREVIEW_RENDER_FAILED"); end
    end.new

    assert_raises(Previews::Renderer::PermanentError) { Previews::Renderer.call(ranking_run, runner: runner) }

    assert_equal "ranked", candidates.first.reload.status
    assert_equal "failed", ranking_run.preview_artifacts.find_by(kind: "thumbnail").status
    assert_equal "running", run.reload.status
    assert_equal "generating_previews", video.reload.status
  end

  test "keeps already completed Top-5 artifacts when a later candidate fails" do
    _video, _run, ranking_run, candidates = build_ranked_video(5)
    runner = Class.new(FakeRunner) do
      def render_preview(source, destination, start_seconds:, duration_seconds:)
        raise Previews::Renderer::PermanentError.new("bad media", code: "PREVIEW_RENDER_FAILED") if start_seconds == 60.0
        super
      end
    end.new

    assert_raises(Previews::Renderer::PermanentError) { Previews::Renderer.call(ranking_run, runner: runner) }

    assert_equal %w[ranked ranked ranked ranked ranked], candidates.map { |candidate| candidate.reload.status }
    assert_equal 6, ranking_run.preview_artifacts.where(status: "ready").count
    assert_empty candidates.last.preview_artifacts
  end

  test "the job records permanent failures without exposing command details" do
    video, run, ranking_run, = build_ranked_video(1)
    candidate = ranking_run.candidate_scores.first.candidate_clip
    artifact = ranking_run.preview_artifacts.create!(
      candidate_clip: candidate,
      kind: "preview",
      render_version: Previews::Renderer::VERSION,
      status: "rendering",
      start_ms: candidate.start_ms,
      end_ms: candidate.end_ms,
      duration_ms: candidate.duration_ms
    )
    error = Previews::Renderer::PermanentError.new("source /secret/path/token is invalid", code: "SOURCE_MEDIA_INVALID")
    singleton = Previews::Renderer.singleton_class
    original_call = Previews::Renderer.method(:call)
    singleton.define_method(:call) { |*| raise error }
    begin
      RenderPreviewsJob.perform_now(video.id, run.id, ranking_run.id)
    ensure
      singleton.define_method(:call, original_call)
    end

    assert_equal "failed", run.reload.status
    assert_equal "SOURCE_MEDIA_INVALID", run.error_code
    assert_equal "failed", video.reload.status
    assert_equal "failed", artifact.reload.status
    refute_includes run.error_message, "/secret/path"
  end

  test "a late job does not render after the run is complete" do
    video, run, ranking_run, = build_ranked_video(1)
    run.update!(status: "succeeded", current_stage: "complete", completed_at: Time.current)
    video.update!(status: "complete", completed_at: Time.current)
    singleton = Previews::Renderer.singleton_class
    original_call = Previews::Renderer.method(:call)
    called = false
    singleton.define_method(:call) { |*| called = true }
    begin
      RenderPreviewsJob.perform_now(video.id, run.id, ranking_run.id)
    ensure
      singleton.define_method(:call, original_call)
    end

    assert_not called
    assert_empty ranking_run.preview_artifacts
  end

  test "an inactive renderer cannot downgrade a terminal run" do
    video, run, ranking_run, = build_ranked_video(1)
    singleton = Previews::Renderer.singleton_class
    original_call = Previews::Renderer.method(:call)
    singleton.define_method(:call) do |*|
      run.update!(status: "succeeded", current_stage: "complete", completed_at: Time.current)
      video.update!(status: "complete", completed_at: Time.current)
      raise Previews::Renderer::PermanentError.new("inactive", code: "PREVIEW_RUN_INACTIVE")
    end
    begin
      RenderPreviewsJob.perform_now(video.id, run.id, ranking_run.id)
    ensure
      singleton.define_method(:call, original_call)
    end

    assert_equal "succeeded", run.reload.status
    assert_equal "complete", video.reload.status
  end

  private

  def build_ranked_video(count)
    video = create_video(duration_ms: 120_000, status: "generating_previews")
    video.source_media.attach(io: StringIO.new("source"), filename: "source.mp4", content_type: "video/mp4")
    run = video.processing_runs.create!(pipeline_version: video.pipeline_version, idempotency_key: "preview-#{SecureRandom.uuid}", status: "running", current_stage: "generating_previews")
    ranking_run = video.ranking_runs.create!(processing_run: run, feature_version: "features-test", scorer_version: "heuristic-1", config: { "weights" => {} }, status: "succeeded", completed_at: Time.current)
    candidates = count.times.map do |index|
      candidate = create_candidate(video: video, sequence: index, start_ms: index * 20_000, end_ms: (index + 1) * 20_000, transcript: "Candidate #{index + 1}", status: "ranked")
      ranking_run.candidate_scores.create!(candidate_clip: candidate, rank: index + 1, clip_score: 95 - index, content_quality: 90, hook: 90, delivery: 90, pacing: 90, visual_engagement: 90, standalone_clarity: 90, component_details: {})
      candidate
    end
    [ video, run, ranking_run, candidates ]
  end
end
