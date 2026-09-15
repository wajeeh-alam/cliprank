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
end
