class RankingRun < ApplicationRecord
  STATUSES = %w[pending running succeeded failed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :video
  belongs_to :processing_run
  has_many :candidate_scores, dependent: :restrict_with_exception
  has_many :candidate_clips, through: :candidate_scores

  validates :feature_version, :scorer_version, presence: true
  validates :config, hash_payload: true
end
