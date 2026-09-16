require "test_helper"

class ExplanationsGeneratorTest < ActiveSupport::TestCase
  test "creates deterministic evidence-linked explanations from persisted rows" do
    ranking_run = create_ranking_run
    score = create_score(ranking_run: ranking_run)
    create_feature_set(candidate: score.candidate_clip, feature_version: ranking_run.feature_version)

    Explanations::Generator.call(ranking_run)

    explanation = score.reload.explanations.find_by!(explanation_version: Explanations::Generator::VERSION)
    assert_equal "rails-rules-1", explanation.model_version
    assert_includes explanation.summary, score.clip_score.to_s
    assert explanation.strengths.all? { |item| item["source_feature_path"].present? }
    assert explanation.weaknesses.all? { |item| item["source_feature_path"].present? }
    assert explanation.quantitative_facts.all? { |item| item.keys.sort == %w[metric source_feature_path unit value] }
    assert_equal score.clip_score.to_f, explanation.quantitative_facts.find { |item| item["metric"] == "clip_score" }["value"]
    assert_equal 0.75, explanation.quantitative_facts.find { |item| item["metric"] == "hook_strength" }["value"]
    assert_equal 1, score.explanations.count
  end

  test "retries reuse the versioned explanation without duplicates" do
    ranking_run = create_ranking_run
    score = create_score(ranking_run: ranking_run)
    create_feature_set(candidate: score.candidate_clip, feature_version: ranking_run.feature_version)

    Explanations::Generator.call(ranking_run)
    first = score.reload.explanations.find_by!(explanation_version: Explanations::Generator::VERSION)
    Explanations::Generator.call(ranking_run)

    assert_equal first.id, score.reload.explanations.find_by!(explanation_version: Explanations::Generator::VERSION).id
    assert_equal 1, score.explanations.count
  end

  test "does not synthesize an explanation when the same-run feature set is absent" do
    ranking_run = create_ranking_run
    score = create_score(ranking_run: ranking_run)

    assert_raises(Explanations::Generator::Error) { Explanations::Generator.call(ranking_run) }
    assert_empty score.reload.explanations
  end

  test "suppresses visual claims and facts when visual measurement is unavailable" do
    ranking_run = create_ranking_run
    score = create_score(ranking_run: ranking_run)
    create_feature_set(
      candidate: score.candidate_clip,
      feature_version: ranking_run.feature_version,
      raw_metadata: { "capability_warnings" => [ "NO_VIDEO_STREAM" ] }
    )

    Explanations::Generator.call(ranking_run)

    explanation = score.reload.explanations.find_by!(explanation_version: Explanations::Generator::VERSION)
    paths = explanation.strengths.concat(explanation.weaknesses).map { |item| item["source_feature_path"] }
    metrics = explanation.quantitative_facts.map { |item| item["metric"] }
    assert paths.none? { |path| path.start_with?("visual_features.") }
    assert_not_includes metrics, "visual_engagement"
    assert explanation.quantitative_facts.all? { |item| !item["source_feature_path"].start_with?("visual_features.") }
  end
end
