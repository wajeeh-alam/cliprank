require "test_helper"

class CandidateScoreTest < ActiveSupport::TestCase
  test "bounds clip score and independently displayable components" do
    score = create_score
    score.clip_score = 100.01

    assert_not score.valid?
    assert score.errors[:clip_score].any?
  end

  test "belongs to a ranking run and candidate and has explanations" do
    score = create_score

    assert_equal score.ranking_run.video, score.candidate_clip.video
    assert_respond_to score, :explanations
    assert_includes score.ranking_run.candidate_scores, score
  end
end
