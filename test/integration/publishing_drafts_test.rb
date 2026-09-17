require "test_helper"

class PublishingDraftsTest < ActionDispatch::IntegrationTest
  setup do
    @video = create_video
    @candidate = create_candidate(video: @video)
    create_feature_set(candidate: @candidate)
    login_as(@video.user)
  end

  test "creates editable platform drafts from an owned candidate and requires explicit approval" do
    assert_difference "PublishingDraft.count", 1 do
      assert_difference "DraftVariant.count", 2 do
        post publishing_drafts_path, params: { candidate_clip_id: @candidate.id }
      end
    end

    draft = PublishingDraft.order(:id).last
    assert_redirected_to publishing_draft_path(draft)
    assert_equal %w[instagram linkedin], draft.draft_variants.order(:platform).pluck(:platform)
    follow_redirect!
    assert_response :success
    assert_select "fieldset.draft-variant-card", count: 2

    instagram = draft.draft_variants.find_by!(platform: "instagram")
    linkedin = draft.draft_variants.find_by!(platform: "linkedin")
    patch publishing_draft_path(draft), params: {
      draft_variants: {
        instagram.id.to_s => {
          id: instagram.id, title: "An edited Instagram hook", description: "Edited caption",
          hashtags: "#history #OnlyPast", cta: "Save this"
        },
        linkedin.id.to_s => {
          id: linkedin.id, title: "An edited LinkedIn hook", description: "Edited post",
          hashtags: "#Leadership", cta: "Share your experience"
        }
      }
    }
    assert_redirected_to publishing_draft_path(draft)
    assert_equal [ "#history", "#OnlyPast" ], instagram.reload.hashtags

    patch ready_publishing_draft_path(draft)
    assert_redirected_to publishing_draft_path(draft)
    assert draft.reload.ready_for_review?

    patch approve_publishing_draft_path(draft)
    assert_redirected_to publishing_draft_path(draft)
    assert draft.reload.approved?
    assert_predicate draft.approved_payload_digest, :present?
    assert_nil draft.published_at
  end

  test "does not expose another user's draft" do
    other_video = create_video
    draft = PublishingDraft.create!(
      user: other_video.user,
      video: other_video,
      candidate_clip: create_candidate(video: other_video)
    )

    get publishing_draft_path(draft)

    assert_response :not_found
  end

  private

  def login_as(user)
    post login_path, params: { session: { email: user.email, password: "password-123" } }
    assert_redirected_to videos_path
  end
end
