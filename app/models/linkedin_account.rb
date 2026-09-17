class LinkedinAccount < ApplicationRecord
  belongs_to :user
  has_many :linkedin_posts, dependent: :destroy
  has_many :linkedin_insight_snapshots, dependent: :destroy

  validates :linkedin_member_id, :display_name, :access_token_ciphertext, presence: true
  validates :sync_error, length: { maximum: 500 }, allow_nil: true

  def access_token
    Linkedin::TokenCipher.decrypt(access_token_ciphertext)
  end

  def access_token=(token)
    self.access_token_ciphertext = Linkedin::TokenCipher.encrypt(token)
  end

  def access_token?
    access_token_ciphertext.present?
  end

  def serializable_hash(options = nil)
    options = (options || {}).dup
    options[:except] = Array(options[:except]) + [ :access_token_ciphertext ]
    super(options)
  end

  def token_expired?(at = Time.current)
    token_expires_at.present? && token_expires_at <= at
  end
end
