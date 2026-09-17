require "test_helper"

class PublishingContentPackageGeneratorTest < ActiveSupport::TestCase
  test "generates reproducible platform packages from transcript semantic features and brand memory" do
    video = create_video
    candidate = create_candidate(video: video, transcript: "A clear workflow makes every product launch easier.")
    create_feature_set(
      candidate: candidate,
      semantic_features: semantic_features.merge(
        "topic" => "product launch workflow", "content_type" => "educational", "hook_type" => "result_first"
      )
    )
    BrandProfile.create!(
      user: video.user, brand_name: "Build Well", description: "Practical product lessons",
      audience: "independent product builders", voice: "clear and direct",
      content_pillars: [ "product systems" ], preferred_terms: [ "ship clearly" ],
      avoided_terms: [ "hack" ], default_cta: "Share the system you use.", example_posts: [ "Build the smallest useful system." ]
    )
    draft = PublishingDraft.create!(user: video.user, video: video, candidate_clip: candidate)

    Publishing::ContentPackageGenerator.call(draft)
    first_payload = draft.draft_variants.order(:platform).map do |variant|
      variant.attributes.slice("platform", "title", "description", "hashtags", "cta", "evidence")
    end
    Publishing::ContentPackageGenerator.call(draft)
    second_payload = draft.reload.draft_variants.order(:platform).map do |variant|
      variant.attributes.slice("platform", "title", "description", "hashtags", "cta", "evidence")
    end

    assert_equal first_payload, second_payload
    assert_equal %w[instagram linkedin], draft.draft_variants.order(:platform).pluck(:platform)
    assert_equal Publishing::ContentPackageGenerator::VERSION, draft.generator_version
    assert draft.generated_at.present?
    draft.draft_variants.each do |variant|
      assert_equal "Share the system you use.", variant.cta
      assert_includes variant.evidence.fetch("sources"), "brand_profile"
      assert_equal "product launch workflow", variant.evidence.fetch("topic")
    end
  end

  test "uses only past Instagram performance signals and labels their scope" do
    video = create_video
    candidate = create_candidate(video: video, transcript: "Workflow lessons for a better launch.")
    create_feature_set(
      candidate: candidate,
      semantic_features: semantic_features.merge("topic" => "launch workflow")
    )
    account = video.user.instagram_accounts.create!(
      instagram_user_id: "history-creator", username: "creator", account_type: "CREATOR", access_token: "token"
    )
    5.times do |index|
      media = account.instagram_media.create!(
        instagram_media_id: "history-#{index}", media_type: "VIDEO",
        caption: "Workflow launch clarity", published_at: index.days.ago
      )
      account.instagram_insight_snapshots.create!(
        instagram_media: media, captured_on: Date.current - index,
        captured_at: Time.current - index.days, metrics: { "total_interactions" => index + 1, "views" => 100 }
      )
    end
    draft = PublishingDraft.create!(user: video.user, video: video, candidate_clip: candidate)

    Publishing::ContentPackageGenerator.call(draft)

    evidence = draft.draft_variants.first.evidence.fetch("instagram_history")
    assert_equal 5, evidence.fetch("sample_size")
    assert_includes evidence.fetch("terms"), "workflow"
    assert_match(/past Instagram posts/, evidence.fetch("label"))
    assert_match(/not a prediction or global trends feed/, evidence.fetch("label"))
  end

  test "rejects regeneration after human approval" do
    video = create_video
    candidate = create_candidate(video: video)
    create_feature_set(candidate: candidate)
    draft = PublishingDraft.create!(user: video.user, video: video, candidate_clip: candidate)
    Publishing::ContentPackageGenerator.call(draft)
    draft.mark_ready_for_review!
    draft.approve!

    error = assert_raises(Publishing::ContentPackageGenerator::Error) do
      Publishing::ContentPackageGenerator.call(draft)
    end
    assert_equal "Only editable drafts can generate content", error.message
  end
end
