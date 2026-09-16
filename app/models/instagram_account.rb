class InstagramAccount < ApplicationRecord
  ACCOUNT_TYPES = %w[BUSINESS CREATOR].freeze

  belongs_to :user
  has_many :instagram_media, class_name: "InstagramMedia", dependent: :destroy
  has_many :instagram_insight_snapshots, dependent: :destroy

  validates :instagram_user_id, :username, :access_token_ciphertext, presence: true
  validates :account_type, inclusion: { in: ACCOUNT_TYPES }
  validates :sync_error, length: { maximum: 500 }, allow_nil: true

  # Deliberately not an Active Record column: plaintext is only held in memory
  # while making a provider request and is absent from inspect/as_json output.
  def access_token
    Instagram::TokenCipher.decrypt(access_token_ciphertext)
  end

  def access_token=(token)
    self.access_token_ciphertext = Instagram::TokenCipher.encrypt(token)
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

  def token_expiring_soon?(at = Time.current)
    token_expires_at.present? && token_expires_at <= at + 7.days
  end
end
