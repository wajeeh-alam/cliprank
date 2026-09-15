require "test_helper"

class CandidateClipTest < ActiveSupport::TestCase
  test "enforces generated candidate duration and timestamp consistency" do
    candidate = create_candidate
    candidate.end_ms = 60_001
    candidate.duration_ms = 60_001

    assert_not candidate.valid?
    assert candidate.errors[:duration_ms].any?
  end

  test "exposes feature, ranking, export, and preview relationships" do
    candidate = create_candidate

    assert_respond_to candidate, :candidate_feature_sets
    assert_respond_to candidate, :candidate_scores
    assert_respond_to candidate, :ranking_runs
    assert_respond_to candidate, :exports
    assert_respond_to candidate, :preview
    assert_respond_to candidate, :thumbnail
  end
end
