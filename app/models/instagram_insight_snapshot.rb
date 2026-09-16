class InstagramInsightSnapshot < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_media, class_name: "InstagramMedia"

  validates :captured_on, :captured_at, presence: true
  validates :metrics, hash_payload: true
  validate :media_belongs_to_account

  private

  def media_belongs_to_account
    return if instagram_media.blank? || instagram_account.blank?
    return if instagram_media.instagram_account_id == instagram_account_id

    errors.add(:instagram_media, "must belong to the Instagram account")
  end
end
