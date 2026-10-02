class Publication < ApplicationRecord
  PLATFORMS = %w[instagram linkedin].freeze
  SOURCES = %w[manual csv collector fixture].freeze

  belongs_to :user
  belongs_to :candidate_clip
  belongs_to :ranking_prediction
  has_many :metric_snapshots, dependent: :restrict_with_exception

  validates :platform, inclusion: { in: PLATFORMS }
  validates :source, inclusion: { in: SOURCES }
  validates :platform_account_key, :post_id, :published_at, presence: true
  validates :post_id, uniqueness: { scope: %i[platform platform_account_key] }
  validates :post_url, format: URI::DEFAULT_PARSER.make_regexp(%w[http https]), allow_blank: true
  validate :owned_prediction

  def selected_outcome_snapshot
    metric_snapshots.where(post_age_hours: MetricSnapshot::MATURE_AGE_RANGE, views: 0..)
      .order(Arel.sql("ABS(post_age_hours - 72.0) ASC, observed_at ASC")).first
  end

  private

  def owned_prediction
    return if user.blank? || candidate_clip.blank? || ranking_prediction.blank?
    return if candidate_clip.video.user_id == user_id && ranking_prediction.candidate_clip_id == candidate_clip_id

    errors.add(:base, "publication must use an owned clip prediction")
  end
end
