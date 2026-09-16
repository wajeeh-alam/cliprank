class Explanation < ApplicationRecord
  SCORE_SOURCE_PATHS = CandidateScore::SCORE_ATTRIBUTES.map { |attribute| "candidate_score.#{attribute}" }.freeze
  FEATURE_SOURCE_PATHS = (
    CandidateFeatureSet::NORMALIZED_SEMANTIC_FEATURES.map { |key| "semantic_features.#{key}" } +
    CandidateFeatureSet::NORMALIZED_AUDIO_FEATURES.map { |key| "audio_features.#{key}" } +
    CandidateFeatureSet::NORMALIZED_VISUAL_FEATURES.map { |key| "visual_features.#{key}" } +
    CandidateFeatureSet::NORMALIZED_STRUCTURAL_FEATURES.map { |key| "structural_features.#{key}" }
  ).freeze
  SOURCE_PATHS = (SCORE_SOURCE_PATHS + FEATURE_SOURCE_PATHS).freeze

  belongs_to :candidate_score

  validates :explanation_version, :summary, presence: true
  validates :strengths, :weaknesses, :quantitative_facts, array_payload: true
  validate :evidence_payloads

  private

  def evidence_payloads
    { strengths: strengths, weaknesses: weaknesses }.each do |attribute, payload|
      next unless payload.is_a?(Array)

      payload.each_with_index do |item, index|
        valid = item.is_a?(Hash) && item.keys.sort == %w[source_feature_path text value] &&
          item["text"].is_a?(String) && item["text"].present? && finite_number?(item["value"]) &&
          valid_source_path?(item["source_feature_path"])
        unless valid
          errors.add(attribute, "item #{index + 1} must include source_feature_path")
        end
      end
    end

    return unless quantitative_facts.is_a?(Array)

    quantitative_facts.each_with_index do |item, index|
      valid = item.is_a?(Hash) && item.keys.sort == %w[metric source_feature_path unit value] &&
        item["metric"].is_a?(String) && item["metric"].present? && item["unit"].is_a?(String) &&
        item["unit"].present? && finite_number?(item["value"]) && valid_source_path?(item["source_feature_path"])
      errors.add(:quantitative_facts, "item #{index + 1} must include metric, value, unit, and source_feature_path") unless valid
    end
  end

  def finite_number?(value)
    value.is_a?(Numeric) && value.finite?
  end

  def valid_source_path?(path)
    path.is_a?(String) && SOURCE_PATHS.include?(path)
  end
end
