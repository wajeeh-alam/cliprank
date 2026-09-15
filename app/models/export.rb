class Export < ApplicationRecord
  STATUSES = %w[requested rendering ready failed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :candidate_clip
  belongs_to :user
  has_one_attached :rendered_file

  validates :start_ms, :end_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :export_version, presence: true
  validate :timestamp_range

  private

  def timestamp_range
    return if start_ms.blank? || end_ms.blank?

    errors.add(:end_ms, "must be greater than start_ms") unless start_ms < end_ms
  end
end
