require "test_helper"

class FeedbackOutcomesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @video = create_video
    @candidate = create_candidate(video: @video)
    create_feature_set(candidate: @candidate, feature_version: "features-test")
    @ranking_run = create_ranking_run(
      video: @video, feature_version: "features-test", status: "succeeded", completed_at: Time.current
    )
    @score = create_score(ranking_run: @ranking_run, candidate_clip: @candidate)
    login_as(@video.user)
  end

  test "freezes the recommendation, records publication and schedules mature collection" do
    published_at = 1.hour.ago
    assert_enqueued_with(job: CollectPublicationMetricsJob) do
      assert_difference [ "Publication.count", "RankingPrediction.count" ], 1 do
        post publications_path, params: {
          candidate_score_id: @score.id,
          publication: {
            platform: "instagram", platform_account_key: "ig-user-1", post_id: "media-1",
            post_url: "https://www.instagram.com/reel/example/", published_at: published_at
          }
        }
      end
    end

    publication = Publication.last
    prediction = publication.ranking_prediction
    assert_redirected_to feedback_dashboard_path
    assert_equal @candidate, publication.candidate_clip
    assert_equal @score.clip_score, prediction.baseline_score
    assert_equal "features-test", prediction.schema_version
    assert_equal 4, prediction.frozen_features.keys.length
    follow_redirect!
    assert_response :success
    assert_select "h1", "Outcome feedback ranker"

    get publication_path(publication)
    assert_response :success
    assert_select "h2", "Timestamped snapshots"
  end

  test "manual missing metrics remain missing and do not become a label" do
    publication = create_publication
    post publication_metric_snapshots_path(publication), params: {
      metric_snapshot: { observed_at: publication.published_at + 72.hours, likes: 10 }
    }

    assert_redirected_to publication_path(publication)
    snapshot = publication.metric_snapshots.last
    assert_nil snapshot.views
    assert_not snapshot.mature?
    assert_nil publication.selected_outcome_snapshot
  end

  test "rejects duplicate external posts and cannot publish another user's score" do
    create_publication
    assert_no_difference "Publication.count" do
      post publications_path, params: {
        candidate_score_id: @score.id,
        publication: {
          platform: "instagram", platform_account_key: "ig-user-1", post_id: "media-1",
          published_at: Time.current
        }
      }
    end
    assert_response :unprocessable_entity

    other_video = create_video
    other_candidate = create_candidate(video: other_video)
    other_run = create_ranking_run(video: other_video)
    other_score = create_score(ranking_run: other_run, candidate_clip: other_candidate)
    get new_publication_path(candidate_score_id: other_score.id)
    assert_response :not_found
  end

  test "renders the publication form for an owned ranked candidate" do
    get new_publication_path(candidate_score_id: @score.id)

    assert_response :success
    assert_select "h1", "Mark this clip as published"
    assert_select "input[name=candidate_score_id][value='#{@score.id}']"
  end

  private

  def create_publication
    prediction = create_prediction(ranking_run: @ranking_run, candidate_clip: @candidate)
    @video.user.publications.create!(
      candidate_clip: @candidate,
      ranking_prediction: prediction,
      platform: "instagram",
      platform_account_key: "ig-user-1",
      post_id: "media-1",
      published_at: 3.days.ago,
      source: "manual"
    )
  end

  def login_as(user)
    post login_path, params: { session: { email: user.email, password: "password-123" } }
    assert_redirected_to videos_path
  end
end
