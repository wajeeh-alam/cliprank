require "test_helper"

class DraftVariantTest < ActiveSupport::TestCase
  test "allows only supported platforms and normalized hashtag arrays" do
    video = create_video
    draft = PublishingDraft.create!(user: video.user, video: video, candidate_clip: create_candidate(video: video))
    variant = draft.draft_variants.build(
      platform: "tiktok", title: "A useful coding lesson", description: "Try this.",
      hashtags: [ "coding", "#valid_tag" ], evidence: {}
    )

    assert_not variant.valid?
    assert variant.errors[:platform].present?
    assert_includes variant.errors[:hashtags], "must be an array of hashtags"
  end
end
