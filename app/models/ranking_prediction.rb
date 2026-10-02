class RankingPrediction < ApplicationRecord
  belongs_to :ranking_run
  belongs_to :candidate_clip
  belongs_to :model_version, optional: true
  has_many :publications, dependent: :restrict_with_exception

  validates :schema_version, :feature_model_version, :baseline_model_version, :selected_scorer, :recommended_at, presence: true
  validates :baseline_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :baseline_rank, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :feedback_score, numericality: true, allow_nil: true
  validates :feedback_display_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :feedback_rank, numericality: { only_integer: true, greater_than_or_equal_to: 1 }, allow_nil: true
  validates :frozen_features, hash_payload: true
  validate :contributions_are_array
  validate :candidate_belongs_to_run

  def feedback_selected?
    model_version.present? && selected_scorer == model_version.version && fallback_reason.nil?
  end

  private

  def contributions_are_array
    errors.add(:model_contributions, "must be an array") unless model_contributions.is_a?(Array)
  end

  def candidate_belongs_to_run
    return if ranking_run.blank? || candidate_clip.blank? || ranking_run.video_id == candidate_clip.video_id

    errors.add(:candidate_clip, "must belong to the ranking run's video")
  end
end
