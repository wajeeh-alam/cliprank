class ProcessingRun < ApplicationRecord
  STATUSES = %w[pending running succeeded failed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :video
  has_many :ranking_runs, dependent: :restrict_with_exception

  validates :pipeline_version, :idempotency_key, presence: true
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :error_details, hash_payload: true
  validates :candidate_processing_mode, inclusion: { in: %w[audit repurpose] }, allow_nil: true
end
