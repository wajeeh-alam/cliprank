class InstagramMedia < ApplicationRecord
  MEDIA_TYPES = %w[IMAGE VIDEO CAROUSEL_ALBUM].freeze

  belongs_to :instagram_account
  has_many :instagram_insight_snapshots, dependent: :destroy

  validates :instagram_media_id, :media_type, presence: true
  validates :media_type, inclusion: { in: MEDIA_TYPES }
  validates :metadata, hash_payload: true
end
