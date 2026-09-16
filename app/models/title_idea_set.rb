class TitleIdeaSet < ApplicationRecord
  SOURCE_TYPES = %w[transcript instagram_history].freeze

  belongs_to :ranking_run
  belongs_to :candidate_clip
  has_many :title_ideas, dependent: :destroy

  validates :version, :source_type, presence: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :sample_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :evidence, hash_payload: true
  validate :candidate_belongs_to_ranking_video
  validate :candidate_was_ranked

  private

  def candidate_belongs_to_ranking_video
    return if ranking_run.blank? || candidate_clip.blank?
    return if ranking_run.video_id == candidate_clip.video_id

    errors.add(:candidate_clip, "must belong to the ranking run's video")
  end


  def candidate_was_ranked
    return if ranking_run.blank? || candidate_clip.blank?
    return if ranking_run.candidate_scores.exists?(candidate_clip_id: candidate_clip_id)

    errors.add(:candidate_clip, "must be ranked in the ranking run")
  end
end
