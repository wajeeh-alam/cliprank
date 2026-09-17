class LinkedinPost < ApplicationRecord
  belongs_to :linkedin_account
  has_many :linkedin_insight_snapshots, dependent: :destroy

  validates :linkedin_post_urn, presence: true
  validates :metadata, hash_payload: true
end
