require "test_helper"

class RankedResultsTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "ranked@example.com", password: "password-123")
  end

  test "shows only the ordered Top 5 with evidence and accessible status" do
    video, ranking_run = build_ranked_video(count: 6)
    Explanations::Generator.call(ranking_run)
    login

    get video_path(video)

    assert_response :success
    assert_select "section[aria-live='polite'][aria-label='Ranked clip results']"
    assert_select ".result-card", count: 5
    assert_select ".result-transcript", text: "Ranked candidate 1"
    assert_select ".result-transcript", text: "Ranked candidate 5"
    assert_select ".result-transcript", text: "Ranked candidate 6", count: 0
    assert_select ".explanation-block", count: 5
  end

  test "gates a successful ranking until every score has an explanation" do
    video, = build_ranked_video(count: 1)
    login

    get video_path(video)

    assert_response :success
    assert_select ".results-section", count: 0
    assert_select ".results-empty", /almost ready/i
  end

  test "does not render a corrupted cross-video score" do
    video, ranking_run = build_ranked_video(count: 1)
    Explanations::Generator.call(ranking_run)
    other_candidate = create_candidate
    ranking_run.candidate_scores.first.update_column(:candidate_clip_id, other_candidate.id)
    login

    get video_path(video)

    assert_response :success
    assert_select ".results-section", count: 0
    assert_select ".results-empty", /almost ready/i
    assert_select ".result-transcript", text: other_candidate.transcript, count: 0
  end

  private

  def login
    post login_path, params: { session: { email: @user.email, password: "password-123" } }
    assert_redirected_to videos_path
  end

  def build_ranked_video(count:)
    video = @user.videos.create!(title: "Ranked recording", pipeline_version: "phase1", status: "generating_previews")
    processing_run = video.processing_runs.create!(
      pipeline_version: video.pipeline_version,
      idempotency_key: "ranked-results-#{SecureRandom.uuid}",
      status: "running",
      current_stage: "ranking_complete"
    )
    ranking_run = video.ranking_runs.create!(
      processing_run: processing_run,
      feature_version: "features-test",
      scorer_version: "heuristic-1",
      config: { "weights" => { "semantic" => 0.35 } },
      status: "succeeded",
      completed_at: Time.current
    )
    count.times do |index|
      candidate = create_candidate(
        video: video,
        sequence: index,
        start_ms: index * 20_000,
        end_ms: (index + 1) * 20_000,
        transcript: "Ranked candidate #{index + 1}"
      )
      create_feature_set(candidate: candidate, feature_version: ranking_run.feature_version)
      create_score(ranking_run: ranking_run, candidate_clip: candidate, rank: index + 1, clip_score: 95 - index)
    end
    [ video, ranking_run ]
  end
end
