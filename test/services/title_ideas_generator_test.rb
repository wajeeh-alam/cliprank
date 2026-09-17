require "test_helper"

class TitleIdeasGeneratorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  test "generates three reproducible title ideas per displayed ranked clip" do
    video = create_video
    ranking_run = create_ranking_run(video: video, status: "succeeded")
    candidate = create_candidate(video: video, transcript: "How I make a useful coding plan.")
    create_feature_set(candidate: candidate, feature_version: ranking_run.feature_version)
    score = create_score(ranking_run: ranking_run, candidate_clip: candidate)

    GenerateTitleIdeasJob.perform_now(ranking_run.id)
    first_titles = candidate.title_idea_sets.first.title_ideas.order(:rank).pluck(:title)
    GenerateTitleIdeasJob.perform_now(ranking_run.id)

    title_set = candidate.reload.title_idea_sets.find_by(version: TitleIdeas::Generator::VERSION)
    assert_equal "transcript", title_set.source_type
    assert_equal 0, title_set.sample_size
    assert_equal 3, title_set.title_ideas.count
    assert_equal first_titles, title_set.title_ideas.order(:rank).pluck(:title)
    assert_equal [ 1, 2, 3 ], title_set.title_ideas.order(:rank).pluck(:rank)
    assert_equal 1, TitleIdeaSet.where(ranking_run: ranking_run, candidate_clip: candidate).count
    assert_equal score.candidate_clip_id, title_set.candidate_clip_id
    assert_equal "succeeded", ranking_run.reload.title_ideas_status
    assert_equal TitleIdeas::Generator::VERSION, ranking_run.title_ideas_version
    title_set.title_ideas.each do |idea|
      assert_operator idea.title.split.length, :>=, 4
      assert_operator idea.title.split.length, :<=, 12
    end
  end

  test "uses creator-history signals only after five posts and labels their scope" do
    video = create_video
    account = video.user.instagram_accounts.create!(
      instagram_user_id: "creator-123", username: "creator", account_type: "CREATOR", access_token: "token"
    )
    5.times do |index|
      media = account.instagram_media.create!(
        instagram_media_id: "media-#{index}", media_type: "VIDEO", caption: "Career coding lessons"
      )
      account.instagram_insight_snapshots.create!(
        instagram_media: media, captured_on: Date.current, captured_at: Time.current,
        metrics: { "total_interactions" => index + 1 }
      )
    end
    ranking_run = create_ranking_run(video: video, status: "succeeded")
    candidate = create_candidate(video: video, transcript: "A clear coding lesson.")
    create_feature_set(candidate: candidate, feature_version: ranking_run.feature_version)
    create_score(ranking_run: ranking_run, candidate_clip: candidate)

    TitleIdeas::Generator.call(ranking_run)

    title_set = candidate.reload.title_idea_sets.first
    assert_equal "instagram_history", title_set.source_type
    assert_equal 5, title_set.sample_size
    assert_match(/creator history/i, title_set.evidence.fetch("label"))
    assert_includes title_set.evidence.fetch("caption_terms"), "coding"
    assert_includes title_set.title_ideas.pluck(:title).join(" ").downcase, "coding"
  end

  test "title generation errors are isolated and recorded without failing ranking" do
    video = create_video
    ranking_run = create_ranking_run(video: video, status: "succeeded")

    GenerateTitleIdeasJob.perform_now(
      ranking_run.id,
      generator: ->(_run) { raise TitleIdeas::Generator::Error, "bad caption" }
    )

    assert_equal "succeeded", ranking_run.reload.status
    assert_equal "failed", ranking_run.title_ideas_status
    assert_equal "bad caption", ranking_run.title_ideas_error
    assert_empty TitleIdeaSet.where(ranking_run: ranking_run)
  end

  test "unexpected title errors transition the artifact status to failed" do
    video = create_video
    ranking_run = create_ranking_run(video: video, status: "succeeded")

    GenerateTitleIdeasJob.perform_now(ranking_run.id, generator: ->(_run) { raise NoMethodError, "broken input" })

    assert_equal "succeeded", ranking_run.reload.status
    assert_equal "failed", ranking_run.title_ideas_status
    assert_match(/broken input/, ranking_run.title_ideas_error)
  end

  test "a late failure cannot overwrite a successful duplicate generation" do
    ranking_run = create_ranking_run(
      status: "succeeded",
      title_ideas_status: "succeeded",
      title_ideas_version: TitleIdeas::Generator::VERSION
    )

    GenerateTitleIdeasJob.new.send(:record_failure, ranking_run.id, RuntimeError.new("late failure"))

    assert_equal "succeeded", ranking_run.reload.title_ideas_status
    assert_nil ranking_run.title_ideas_error
  end

  test "title enqueue claims the current version exactly once" do
    ranking_run = create_ranking_run(status: "succeeded")

    assert_equal true, TitleIdeas::Enqueuer.call(ranking_run)
    assert_equal false, TitleIdeas::Enqueuer.call(ranking_run.reload)

    assert_equal "generating", ranking_run.reload.title_ideas_status
    assert_equal TitleIdeas::Generator::VERSION, ranking_run.title_ideas_version
    assert_equal 1, enqueued_jobs.count { |job| job.fetch(:job) == GenerateTitleIdeasJob }
  end

  test "does not inject an unrelated creator-history term into a clip" do
    video = create_video
    account = video.user.instagram_accounts.create!(
      instagram_user_id: "creator-456", username: "creator", account_type: "CREATOR", access_token: "token"
    )
    5.times do |index|
      account.instagram_media.create!(
        instagram_media_id: "travel-#{index}", media_type: "VIDEO",
        caption: "Travel beaches flights", published_at: index.days.ago,
        like_count: index + 1, comments_count: index
      )
    end
    ranking_run = create_ranking_run(video: video, status: "succeeded")
    candidate = create_candidate(video: video, transcript: "A practical Ruby refactoring technique.")
    create_feature_set(
      candidate: candidate,
      feature_version: ranking_run.feature_version,
      semantic_features: semantic_features.merge("topic" => "Ruby refactoring")
    )
    create_score(ranking_run: ranking_run, candidate_clip: candidate)

    TitleIdeas::Generator.call(ranking_run)

    title_set = candidate.reload.title_idea_sets.first
    assert_equal "transcript", title_set.source_type
    assert_equal false, title_set.title_ideas.pluck(:title).join(" ").match?(/travel|beaches|flights/i)
  end

  test "caps titles at twelve words even when the semantic topic is long" do
    video = create_video
    ranking_run = create_ranking_run(video: video, status: "succeeded")
    candidate = create_candidate(video: video, transcript: "A concise point.")
    create_feature_set(
      candidate: candidate,
      feature_version: ranking_run.feature_version,
      semantic_features: semantic_features.merge("topic" => "one two three four five six seven eight nine ten eleven twelve thirteen")
    )
    create_score(ranking_run: ranking_run, candidate_clip: candidate)

    TitleIdeas::Generator.call(ranking_run)

    assert candidate.reload.title_idea_sets.first.title_ideas.all? { |idea| idea.title.split.length <= 12 }
  end

  test "uses meaningful transcript structure instead of generic classifier labels" do
    video = create_video
    ranking_run = create_ranking_run(video: video, status: "succeeded")
    candidate = create_candidate(
      video: video,
      transcript: "So this is a test for clip rank this video is going to be about me and my friends Hopefully this is a good clip"
    )
    create_feature_set(
      candidate: candidate,
      feature_version: ranking_run.feature_version,
      semantic_features: semantic_features.merge("topic" => "other", "content_type" => "other", "hook_type" => "personal_story")
    )
    create_score(ranking_run: ranking_run, candidate_clip: candidate)

    TitleIdeas::Generator.call(ranking_run)

    titles = candidate.reload.title_idea_sets.first.title_ideas.order(:rank).pluck(:title)
    assert_equal "Testing Clip Rank With Me And My Friends", titles.first
    assert_includes titles, "Me And My Friends"
    assert_includes titles, "Will This Be A Good Clip?"
    assert titles.none? { |title| title.match?(/\bother\b|the idea behind|making sense of/i) }
  end
end
