require "test_helper"

class PublishingDraftTest < ActiveSupport::TestCase
  test "draft belongs to one user's video and selected candidate" do
    video = create_video
    candidate = create_candidate(video: video)

    draft = PublishingDraft.new(user: video.user, video: video, candidate_clip: candidate)

    assert draft.valid?
  end

  test "rejects a candidate from another video and a video from another user" do
    video = create_video
    other_video = create_video
    draft = PublishingDraft.new(user: other_video.user, video: video, candidate_clip: other_video.candidate_clips.create!(
      sequence: 1, start_ms: 0, end_ms: 20_000, duration_ms: 20_000,
      transcript: "Another idea.", generation_version: "candidate-test"
    ))

    assert_not draft.valid?
    assert_includes draft.errors[:video], "must belong to the draft's user"
    assert_includes draft.errors[:candidate_clip], "must belong to the draft's video"
  end

  test "requires explicit valid workflow transitions" do
    video = create_video
    draft = PublishingDraft.create!(user: video.user, video: video, candidate_clip: create_candidate(video: video))

    assert_not draft.update(status: "published")
    assert_includes draft.errors[:status], "cannot transition from draft to published"
  end

  test "approval records a digest and freezes the approved variants" do
    video = create_video
    draft = PublishingDraft.create!(user: video.user, video: video, candidate_clip: create_candidate(video: video))
    variant = draft.draft_variants.create!(
      platform: "instagram", title: "A useful coding lesson", description: "Try this approach.",
      hashtags: [ "#coding", "#tutorial" ], cta: "Save this.", evidence: { "source" => "transcript" }
    )

    draft.mark_ready_for_review!
    draft.approve!(at: Time.zone.parse("2026-09-17 12:00:00"))

    assert draft.approved?
    assert_equal 64, draft.approved_payload_digest.length
    assert_equal draft.payload_digest, draft.approved_payload_digest
    assert_equal Time.zone.parse("2026-09-17 12:00:00"), draft.approved_at
    assert_not variant.update(title: "Changed after approval")
    assert_includes variant.errors[:base], "approved publishing drafts cannot be edited"
  end

  test "requires a complete platform variant before review" do
    video = create_video
    draft = PublishingDraft.create!(user: video.user, video: video, candidate_clip: create_candidate(video: video))

    assert_raises(ActiveRecord::RecordInvalid) { draft.mark_ready_for_review! }
    assert draft.reload.draft?
  end

  test "publishing can finish successfully or record a failure" do
    video = create_video
    draft = PublishingDraft.create!(user: video.user, video: video, candidate_clip: create_candidate(video: video))
    draft.draft_variants.create!(
      platform: "linkedin", title: "A useful coding lesson", description: "Try this approach.",
      hashtags: [ "#coding" ], evidence: {}
    )
    draft.mark_ready_for_review!
    draft.approve!
    draft.start_publishing!
    draft.mark_failed!(message: "Provider temporarily unavailable")

    assert draft.failed?
    assert_equal "Provider temporarily unavailable", draft.error_message
    assert draft.approved_payload_digest.present?
  end
end
