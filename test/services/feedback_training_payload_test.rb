require "test_helper"

class FeedbackTrainingPayloadTest < ActiveSupport::TestCase
  test "real publications exclude demo rows while demo-only platforms remain usable" do
    real = create_publication(platform: "instagram", post_id: "real-post", demo_data: false)
    create_publication(platform: "instagram", post_id: "demo-post", demo_data: true)
    demo_only = create_publication(platform: "linkedin", post_id: "urn:li:share:123", demo_data: true)

    instagram = Feedback::TrainingPayload.call(platform: "instagram", schema_version: "features-test")
    linkedin = Feedback::TrainingPayload.call(platform: "linkedin", schema_version: "features-test")

    assert_equal [ real.id.to_s ], instagram.fetch("publications").pluck("publication_id")
    assert_equal [ demo_only.id.to_s ], linkedin.fetch("publications").pluck("publication_id")
  end

  private

  def create_publication(platform:, post_id:, demo_data:)
    video = create_video
    candidate = create_candidate(video: video)
    create_feature_set(candidate: candidate)
    ranking_run = create_ranking_run(video: video, status: "succeeded", completed_at: Time.current)
    prediction = create_prediction(ranking_run: ranking_run, candidate_clip: candidate)
    video.user.publications.create!(
      candidate_clip: candidate,
      ranking_prediction: prediction,
      platform: platform,
      platform_account_key: "account-#{platform}",
      post_id: post_id,
      published_at: 3.days.ago,
      source: demo_data ? "fixture" : "manual",
      demo_data: demo_data
    )
  end
end
