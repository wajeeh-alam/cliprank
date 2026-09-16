class CandidateClip < ApplicationRecord
  STATUSES = %w[pending analyzing ranked rendering ready failed rejected].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :video
  has_many :candidate_feature_sets, dependent: :restrict_with_exception
  has_many :candidate_scores, dependent: :restrict_with_exception
  has_many :ranking_runs, through: :candidate_scores
  has_many :exports, dependent: :restrict_with_exception
  has_many :preview_artifacts, dependent: :restrict_with_exception
  has_many :title_idea_sets, dependent: :destroy
  has_one_attached :preview
  has_one_attached :thumbnail

  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :transcript, :generation_version, presence: true
  validates :start_ms, :end_ms, :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :duration_ms, numericality: { in: 3_000..60_000 }
  validate :timestamp_range
  validate :recommended_timestamp_range

  private

  def timestamp_range
    return if start_ms.blank? || end_ms.blank? || duration_ms.blank?

    errors.add(:end_ms, "must be greater than start_ms") unless start_ms < end_ms
    errors.add(:duration_ms, "must equal end_ms - start_ms") unless duration_ms == end_ms - start_ms
  end

  def recommended_timestamp_range
    return if recommended_start_ms.nil? && recommended_end_ms.nil?

    if recommended_start_ms.nil? || recommended_end_ms.nil? || recommended_start_ms < 0 || recommended_start_ms >= recommended_end_ms
      errors.add(:recommended_start_ms, "must define a valid recommended range")
    end
  end
end
