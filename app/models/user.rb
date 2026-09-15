class User < ApplicationRecord
  has_many :videos, dependent: :restrict_with_exception
  has_many :exports, dependent: :restrict_with_exception

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: { case_sensitive: false }
  validates :name, length: { maximum: 255 }, allow_nil: true
end
