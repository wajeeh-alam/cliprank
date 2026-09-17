class LinkedinInsightSnapshot < ApplicationRecord
  belongs_to :linkedin_account
  belongs_to :linkedin_post

  validates :captured_on, :captured_at, presence: true
  validates :metrics, hash_payload: true
  validate :post_belongs_to_account

  private

  def post_belongs_to_account
    return if linkedin_post.blank? || linkedin_account.blank?
    return if linkedin_post.linkedin_account_id == linkedin_account_id

    errors.add(:linkedin_post, "must belong to the LinkedIn account")
  end
end
