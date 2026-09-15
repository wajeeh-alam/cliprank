require "test_helper"

class CandidateFeatureSetTest < ActiveSupport::TestCase
  test "requires the semantic feature schema and normalized ranges" do
    feature_set = create_feature_set
    feature_set.semantic_features["hook_strength"] = 1.2

    assert_not feature_set.valid?
    assert feature_set.errors[:semantic_features].any?
  end

  test "rejects missing semantic classifier fields" do
    feature_set = create_feature_set
    feature_set.semantic_features = { "hook_strength" => 0.5 }

    assert_not feature_set.valid?
    assert feature_set.errors[:semantic_features].any?
  end

  test "relates immutable versions to one candidate" do
    feature_set = create_feature_set

    assert_equal feature_set.candidate_clip_id, feature_set.candidate_clip.id
    assert_includes feature_set.candidate_clip.candidate_feature_sets, feature_set
  end
end
