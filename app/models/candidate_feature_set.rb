class CandidateFeatureSet < ApplicationRecord
  NORMALIZED_SEMANTIC_FEATURES = %w[
    hook_strength standalone_clarity information_density novelty emotional_intensity
    quotability payoff_strength story_completeness technical_depth call_to_action_presence
  ].freeze

  belongs_to :candidate_clip

  validates :feature_version, presence: true
  validate :payload_objects
  validate :semantic_schema

  private

  def payload_objects
    {
      semantic_features: semantic_features,
      audio_features: audio_features,
      visual_features: visual_features,
      structural_features: structural_features,
      raw_metadata: raw_metadata
    }.each do |name, payload|
      errors.add(name, "must be a JSON object") unless payload.is_a?(Hash)
    end
  end

  def semantic_schema
    return unless semantic_features.is_a?(Hash)

    (NORMALIZED_SEMANTIC_FEATURES + %w[topic content_type hook_type]).each do |key|
      errors.add(:semantic_features, "is missing #{key}") unless semantic_features.key?(key)
    end

    NORMALIZED_SEMANTIC_FEATURES.each do |key|
      value = semantic_features[key]
      next if value.is_a?(Numeric) && value.between?(0.0, 1.0)

      errors.add(:semantic_features, "#{key} must be between 0 and 1")
    end
  end
end
