require "test_helper"

class FeedbackCsvImporterTest < ActiveSupport::TestCase
  setup do
    video = create_video
    candidate = create_candidate(video: video)
    ranking_run = create_ranking_run(video: video, feature_version: "features-test")
    prediction = create_prediction(ranking_run: ranking_run, candidate_clip: candidate)
    @publication = video.user.publications.create!(
      candidate_clip: candidate,
      ranking_prediction: prediction,
      platform: "instagram",
      platform_account_key: "ig-csv",
      post_id: "csv-post",
      published_at: Time.zone.parse("2026-01-01 00:00:00"),
      source: "manual"
    )
    @csv = <<~CSV
      post_id,observed_at,views,likes
      csv-post,2026-01-04T00:00:00Z,1500,90
    CSV
  end

  test "imports a timestamped outcome once and reports an identical row as duplicate" do
    first = Feedback::CsvImporter.call(
      user: @publication.user, platform: "instagram", platform_account_key: "ig-csv", csv: @csv
    )
    second = Feedback::CsvImporter.call(
      user: @publication.user, platform: "instagram", platform_account_key: "ig-csv", csv: @csv
    )

    assert_equal 1, first.created
    assert_equal 0, first.duplicates
    assert_equal 0, second.created
    assert_equal 1, second.duplicates
    assert_equal 1, @publication.metric_snapshots.count
    assert @publication.metric_snapshots.first.mature?
  end
end
