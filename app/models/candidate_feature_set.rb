class CandidateFeatureSet < ApplicationRecord
  NORMALIZED_SEMANTIC_FEATURES = %w[
    hook_strength standalone_clarity information_density novelty emotional_intensity
    quotability payoff_strength story_completeness technical_depth call_to_action_presence
  ].freeze
  NORMALIZED_AUDIO_FEATURES = %w[
    words_per_minute average_audio_energy energy_variance energy_change_at_hook
    silence_ratio longest_pause_ms pause_frequency
  ].freeze
  NORMALIZED_VISUAL_FEATURES = %w[
    face_presence_ratio visual_motion scene_change_rate screen_recording_ratio
    camera_change_frequency sample_count
  ].freeze
  NORMALIZED_STRUCTURAL_FEATURES = %w[
    time_to_main_point_ms intro_length_ms sentence_completeness
    hook_to_payoff_time_ms dead_air_start_ms dead_air_end_ms
  ].freeze
  CONTENT_TYPES = %w[story tutorial opinion project_demo career_advice coding_tip educational announcement other].freeze
  HOOK_TYPES = %w[question contrarian surprising_claim personal_story result_first problem curiosity_gap none].freeze

  belongs_to :candidate_clip

  validates :feature_version, :model_version, presence: true
  validate :payload_objects
  validate :semantic_schema
  validate :audio_schema
  validate :visual_schema
  validate :structural_schema

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
    errors.add(:semantic_features, "topic must be a non-empty string") unless semantic_features["topic"].is_a?(String) && !semantic_features["topic"].empty?
    errors.add(:semantic_features, "content_type is unsupported") unless CONTENT_TYPES.include?(semantic_features["content_type"])
    errors.add(:semantic_features, "hook_type is unsupported") unless HOOK_TYPES.include?(semantic_features["hook_type"])
    errors.add(:semantic_features, "contains unknown fields") unless semantic_features.keys.map(&:to_s).sort == (NORMALIZED_SEMANTIC_FEATURES + %w[topic content_type hook_type]).sort
  end

  def audio_schema
    return unless audio_features.is_a?(Hash)

    validate_exact_keys(audio_features, NORMALIZED_AUDIO_FEATURES, :audio_features)
    validate_non_negative_number(audio_features["words_per_minute"], :audio_features, "words_per_minute")
    %w[average_audio_energy energy_variance energy_change_at_hook silence_ratio pause_frequency].each do |key|
      validate_unit_number(audio_features[key], :audio_features, key)
    end
    validate_non_negative_integer(audio_features["longest_pause_ms"], :audio_features, "longest_pause_ms")
  end

  def visual_schema
    return unless visual_features.is_a?(Hash)

    validate_exact_keys(visual_features, NORMALIZED_VISUAL_FEATURES, :visual_features)
    %w[face_presence_ratio visual_motion scene_change_rate screen_recording_ratio camera_change_frequency].each do |key|
      validate_unit_number(visual_features[key], :visual_features, key)
    end
    validate_non_negative_integer(visual_features["sample_count"], :visual_features, "sample_count")
  end

  def structural_schema
    return unless structural_features.is_a?(Hash)

    validate_exact_keys(structural_features, NORMALIZED_STRUCTURAL_FEATURES, :structural_features)
    %w[time_to_main_point_ms intro_length_ms hook_to_payoff_time_ms dead_air_start_ms dead_air_end_ms].each do |key|
      validate_non_negative_integer(structural_features[key], :structural_features, key)
    end
    validate_unit_number(structural_features["sentence_completeness"], :structural_features, "sentence_completeness")
  end

  def validate_exact_keys(payload, expected, attribute)
    errors.add(attribute, "is missing required fields") unless (expected - payload.keys.map(&:to_s)).empty?
    errors.add(attribute, "contains unknown fields") unless (payload.keys.map(&:to_s) - expected).empty?
  end

  def validate_non_negative_number(value, attribute, name)
    errors.add(attribute, "#{name} must be a non-negative number") unless value.is_a?(Numeric) && value >= 0
  end

  def validate_non_negative_integer(value, attribute, name)
    errors.add(attribute, "#{name} must be a non-negative integer") unless value.is_a?(Integer) && value >= 0
  end

  def validate_unit_number(value, attribute, name)
    errors.add(attribute, "#{name} must be between 0 and 1") unless value.is_a?(Numeric) && value.between?(0.0, 1.0)
  end
end
