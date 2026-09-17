require "active_support/message_encryptor"
require "active_support/key_generator"

module Linkedin
  class TokenCipher
    PURPOSE = "cliprank/linkedin/access-token".freeze
    SALT = "cliprank/linkedin/access-token-key".freeze
    KEY_LENGTH = ActiveSupport::MessageEncryptor.key_len("aes-256-gcm")

    class ConfigurationError < StandardError; end

    def self.encrypt(token)
      value = token.to_s
      raise ArgumentError, "access token cannot be blank" if value.empty?

      encryptor.encrypt_and_sign(value, purpose: PURPOSE)
    end

    def self.decrypt(ciphertext)
      return if ciphertext.blank?

      encryptor.decrypt_and_verify(ciphertext, purpose: PURPOSE)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      raise ConfigurationError, "LinkedIn access token could not be decrypted"
    end

    def self.encryptor
      secret = ENV["SECRET_KEY_BASE"].presence || Rails.application.secret_key_base.to_s
      raise ConfigurationError, "SECRET_KEY_BASE is not configured" if secret.blank?

      key = ActiveSupport::KeyGenerator.new(secret).generate_key(SALT, KEY_LENGTH)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
    private_class_method :encryptor
  end
end
