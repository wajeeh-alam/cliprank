require "digest"

class MetricSnapshot < ApplicationRecord
  MATURE_AGE_RANGE = 60.0..84.0
  SOURCES = %w[manual csv instagram_api linkedin_api fixture].freeze
  METRICS = %i[views likes comments shares saves average_watch_time_seconds retention_rate].freeze

  belongs_to :publication

  validates :observed_at, :imported_at, :post_age_hours, :source, :import_fingerprint, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :import_fingerprint, uniqueness: true
  validates :post_age_hours, numericality: { greater_than_or_equal_to: 0 }
  validates :views, :likes, :comments, :shares, :saves,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :average_watch_time_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :retention_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :raw_metrics, hash_payload: true
  before_validation :derive_age_and_fingerprint

  def mature?
    views.present? && MATURE_AGE_RANGE.cover?(post_age_hours.to_f)
  end

  private

  def derive_age_and_fingerprint
    self.imported_at ||= Time.current
    if publication&.published_at && observed_at
      self.post_age_hours = (observed_at - publication.published_at) / 1.hour
    end
    self.import_fingerprint ||= Digest::SHA256.hexdigest([
      publication_id, observed_at&.utc&.iso8601(6), source, source_record_id,
      *METRICS.map { |name| public_send(name) }
    ].join("|"))
  end
end
