require "test_helper"
require "stringio"

class PreviewArtifactsTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "preview-owner@example.com", password: "password-123")
    @video, @ranking_run, @candidate, @score = build_ranked_video
  end

  test "anonymous users are redirected from artifact delivery" do
    artifact = create_artifact(kind: "preview")

    get video_preview_artifact_path(@video, artifact)

    assert_redirected_to login_path
  end

  test "owner can receive a short-lived service URL for a ready artifact" do
    artifact = create_artifact(kind: "preview")

    get video_preview_artifact_path(@video, artifact)

    assert_response :redirect
    assert_match(/active_storage|storage|example\.com/, response.location)
  end

  test "another user cannot access the artifact" do
    artifact = create_artifact(kind: "preview")
    other_user = User.create!(email: "preview-other@example.com", password: "password-123")
    post login_path, params: { session: { email: other_user.email, password: "password-123" } }

    get video_preview_artifact_path(@video, artifact)

    assert_response :not_found
  end

  test "owner cannot access an artifact outside the Top 5" do
    sixth_candidate = create_candidate(video: @video, sequence: 6, start_ms: 60_000, end_ms: 80_000, transcript: "Sixth candidate")
    @ranking_run.candidate_scores.create!(
      candidate_clip: sixth_candidate,
      rank: 6,
      clip_score: 60,
      content_quality: 60,
      hook: 60,
      delivery: 60,
      pacing: 60,
      visual_engagement: 60,
      standalone_clarity: 60,
      component_details: {}
    )
    artifact = create_artifact(candidate_clip: sixth_candidate)
    login_as(@user)

    get video_preview_artifact_path(@video, artifact)

    assert_response :not_found
  end

  test "stale ranking artifacts are not rendered in the current Top 5" do
    Explanations::Generator.call(@ranking_run)
    stale_artifact = create_artifact(kind: "preview")
    stale_artifact.file.attach(io: StringIO.new("old"), filename: "old.mp4", content_type: "video/mp4")
    stale_artifact.update!(status: "ready")

    current_run = @video.processing_runs.create!(
      pipeline_version: @video.pipeline_version,
      idempotency_key: "preview-current-#{SecureRandom.uuid}",
      status: "running",
      current_stage: "generating_previews"
    )
    current_ranking = @video.ranking_runs.create!(
      processing_run: current_run,
      feature_version: "features-current",
      scorer_version: "scorer-current",
      config: { "weights" => { "hook" => 0.2 } },
      status: "succeeded",
      completed_at: 1.minute.from_now
    )
    current_score = current_ranking.candidate_scores.create!(
      candidate_clip: @candidate,
      rank: 1,
      clip_score: 93,
      content_quality: 93,
      hook: 90,
      delivery: 88,
      pacing: 92,
      visual_engagement: 80,
      standalone_clarity: 94,
      component_details: {}
    )
    create_feature_set(candidate: @candidate, feature_version: current_ranking.feature_version)
    Explanations::Generator.call(current_ranking)
    pending = create_artifact(ranking_run: current_ranking, candidate_clip: @candidate, kind: "preview", status: "requested")
    login_as(@user)

    get video_path(@video)

    assert_response :success
    assert_select ".preview-queued", count: 1
    assert_select "video", count: 0
    assert_not_includes response.body, video_preview_artifact_path(@video, stale_artifact)
    get video_preview_artifact_path(@video, stale_artifact)
    assert_response :not_found
    assert_not_nil current_score
    assert_not_nil pending
  end

  test "ready artifacts render thumbnail and an accessible video player" do
    Explanations::Generator.call(@ranking_run)
    preview = create_artifact(kind: "preview")
    thumbnail = create_artifact(kind: "thumbnail")
    preview.file.attach(io: StringIO.new("video"), filename: "clip.mp4", content_type: "video/mp4")
    thumbnail.file.attach(io: StringIO.new("image"), filename: "clip.jpg", content_type: "image/jpeg")
    login_as(@user)

    get video_path(@video)

    assert_response :success
    assert_select "img[src=?]", video_preview_artifact_path(@video, thumbnail)
    assert_select "video[controls][preload='metadata'] source[src=?]", video_preview_artifact_path(@video, preview)
    assert_not_includes response.body, "/rails/active_storage/blobs/"
  end

  test "pending artifacts show a queued state and refresh affordance" do
    Explanations::Generator.call(@ranking_run)
    create_artifact(kind: "preview", status: "requested")
    create_artifact(kind: "thumbnail", status: "rendering")
    login_as(@user)

    get video_path(@video)

    assert_response :success
    assert_select "meta[http-equiv='refresh'][content='10']"
    assert_select ".preview-rendering", count: 1
    assert_select "a", text: "Refresh now"
    assert_select "video", count: 0
  end

  private

  def login_as(user)
    post login_path, params: { session: { email: user.email, password: "password-123" } }
    assert_redirected_to videos_path
  end

  def build_ranked_video
    video = @user.videos.create!(title: "Preview recording", pipeline_version: "phase1", status: "generating_previews")
    processing_run = video.processing_runs.create!(
      pipeline_version: video.pipeline_version,
      idempotency_key: "preview-run-#{SecureRandom.uuid}",
      status: "running",
      current_stage: "generating_previews"
    )
    ranking_run = video.ranking_runs.create!(
      processing_run: processing_run,
      feature_version: "features-preview",
      scorer_version: "scorer-preview",
      config: { "weights" => { "hook" => 0.2 } },
      status: "succeeded",
      completed_at: Time.current
    )
    candidate = create_candidate(video: video, transcript: "Preview candidate")
    create_feature_set(candidate: candidate, feature_version: ranking_run.feature_version)
    score = create_score(ranking_run: ranking_run, candidate_clip: candidate)
    [ video, ranking_run, candidate, score ]
  end

  def create_artifact(ranking_run: @ranking_run, candidate_clip: @candidate, **attributes)
    PreviewArtifact.create!(
      {
        ranking_run: ranking_run,
        candidate_clip: candidate_clip,
        kind: "preview",
        render_version: Previews::Renderer::VERSION,
        status: "ready",
        start_ms: candidate_clip.start_ms,
        end_ms: candidate_clip.end_ms,
        duration_ms: candidate_clip.duration_ms
      }.merge(attributes)
    )
  end
end
