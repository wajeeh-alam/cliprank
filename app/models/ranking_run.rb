class RankingRun < ApplicationRecord
  STATUSES = %w[pending running succeeded failed].freeze
  TITLE_IDEA_STATUSES = %w[pending generating succeeded failed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :video
  belongs_to :processing_run
  has_many :candidate_scores, dependent: :restrict_with_exception
  has_many :candidate_clips, through: :candidate_scores
  has_many :preview_artifacts, dependent: :restrict_with_exception
  has_many :title_idea_sets, dependent: :destroy

  validates :feature_version, :scorer_version, presence: true
  validates :config, hash_payload: true
  validates :title_ideas_status, inclusion: { in: TITLE_IDEA_STATUSES }
  validates :title_ideas_error, length: { maximum: 500 }, allow_nil: true
  validates :title_ideas_version, length: { maximum: 100 }, allow_nil: true
end
