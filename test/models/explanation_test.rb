require "test_helper"

class ExplanationTest < ActiveSupport::TestCase
  test "requires array payloads for user-facing bullets and facts" do
    explanation = create_score.explanations.build(
      explanation_version: "explanation-test",
      summary: "A strong standalone candidate.",
      strengths: { "message" => "not an array" },
      weaknesses: [],
      quantitative_facts: []
    )

    assert_not explanation.valid?
    assert explanation.errors[:strengths].any?
  end

  test "rejects unrecognized evidence paths and extra fact fields" do
    explanation = create_score.explanations.build(
      explanation_version: "explanation-test",
      summary: "Evidence only.",
      strengths: [ { "text" => "Unsupported claim", "value" => 1, "source_feature_path" => "invented.metric" } ],
      weaknesses: [],
      quantitative_facts: [
        {
          "metric" => "clip_score", "value" => 91.25, "unit" => "score",
          "source_feature_path" => "candidate_score.clip_score", "extra" => "not allowed"
        }
      ]
    )

    assert_not explanation.valid?
    assert explanation.errors[:strengths].any?
    assert explanation.errors[:quantitative_facts].any?
  end
end
