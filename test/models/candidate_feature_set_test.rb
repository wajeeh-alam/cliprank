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

  test "validates audio, visual, and structural provenance payloads" do
    feature_set = create_feature_set
    feature_set.model_version = nil
    feature_set.audio_features["silence_ratio"] = 1.2
    feature_set.visual_features["sample_count"] = -1
    feature_set.structural_features["intro_length_ms"] = -1

    assert_not feature_set.valid?
    assert feature_set.errors[:model_version].any?
    assert feature_set.errors[:audio_features].any?
    assert feature_set.errors[:visual_features].any?
    assert feature_set.errors[:structural_features].any?
  end
end
