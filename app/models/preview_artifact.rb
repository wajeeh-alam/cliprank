class PreviewArtifact < ApplicationRecord
  KINDS = %w[preview thumbnail].freeze
  STATUSES = %w[requested rendering ready failed].freeze

  belongs_to :ranking_run
  belongs_to :candidate_clip
  has_one_attached :file

  enum :kind, KINDS.index_by(&:itself), validate: true
  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :render_version, :start_ms, :end_ms, :duration_ms, presence: true
  validates :error_message, length: { maximum: 500 }, allow_nil: true
  validate :same_video
  validate :timestamp_range

  private

  def same_video
    return if ranking_run.blank? || candidate_clip.blank?
    return if ranking_run.video_id == candidate_clip.video_id

    errors.add(:candidate_clip, "must belong to the ranking run's video")
  end

  def timestamp_range
    return if start_ms.blank? || end_ms.blank? || duration_ms.blank?
    errors.add(:end_ms, "must be greater than start_ms") unless start_ms < end_ms
    errors.add(:duration_ms, "must equal end_ms - start_ms") unless duration_ms == end_ms - start_ms
  end
end
