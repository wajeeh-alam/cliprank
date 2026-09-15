require "test_helper"

class VideoTest < ActiveSupport::TestCase
  test "has the source attachment and processing relationships" do
    video = create_video

    assert_equal "uploading", video.status
    assert_respond_to video, :source_media
    assert_respond_to video, :processing_runs
    assert_respond_to video, :transcript_segments
    assert_respond_to video, :candidate_clips
    assert_respond_to video, :ranking_runs
  end

  test "rejects a negative duration" do
    user = build_user
    user.save!
    video = user.videos.build(title: "Recording", pipeline_version: "phase1", duration_ms: -1)

    assert_not video.valid?
    assert video.errors[:duration_ms].any?
  end
end
