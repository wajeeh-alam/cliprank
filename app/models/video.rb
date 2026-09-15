class Video < ApplicationRecord
  STATUSES = %w[
    uploading extracting_audio transcribing generating_candidates extracting_features
    ranking generating_previews complete failed
  ].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :user
  has_many :processing_runs, dependent: :restrict_with_exception
  has_many :transcript_segments, dependent: :restrict_with_exception
  has_many :candidate_clips, dependent: :restrict_with_exception
  has_many :ranking_runs, dependent: :restrict_with_exception
  has_one_attached :source_media

  validates :title, presence: true
  validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :pipeline_version, presence: true
  validates :processing_error_details, hash_payload: true
end
