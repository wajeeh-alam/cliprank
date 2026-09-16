class CandidateScore < ApplicationRecord
  SCORE_ATTRIBUTES = %i[
    clip_score content_quality hook delivery pacing visual_engagement standalone_clarity
  ].freeze

  belongs_to :ranking_run
  belongs_to :candidate_clip
  has_many :explanations, dependent: :restrict_with_exception

  validates :rank, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates(*SCORE_ATTRIBUTES, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 })
  validates :component_details, hash_payload: true
  validate :candidate_belongs_to_ranking_video

  private

  def candidate_belongs_to_ranking_video
    return if ranking_run.blank? || candidate_clip.blank?
    return if ranking_run.video_id == candidate_clip.video_id

    errors.add(:candidate_clip, "must belong to the ranking run's video")
  end
end
