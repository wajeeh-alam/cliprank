module Feedback
  class FeatureSnapshot
    def self.from(feature_set)
      {
        "semantic" => feature_set.semantic_features.deep_dup,
        "audio" => feature_set.audio_features.deep_dup,
        "visual" => feature_set.visual_features.deep_dup,
        "structural" => feature_set.structural_features.deep_dup
      }
    end
  end
end
