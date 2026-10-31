class DemoAccess
  DEFAULT_DAILY_UPLOAD_LIMIT = 3
  DEFAULT_MAX_UPLOAD_BYTES = 250.megabytes
  ACTIVE_VIDEO_STATUSES = (Video::STATUSES - %w[complete failed]).freeze

  class << self
    def signups_enabled?
      boolean_setting("SIGNUPS_ENABLED", default: !Rails.env.production?)
    end

    def upload_allowed?(user)
      return false unless user

      configured = ENV["UPLOAD_ALLOWED_EMAILS"].to_s
      return true if configured.blank? && !Rails.env.production?

      allowed_emails(configured).include?(user.email.to_s.downcase)
    end

    def upload_limit_error(user)
      return "Uploads are disabled for this account." unless upload_allowed?(user)
      return "Wait for the current recording to finish before uploading another." if user.videos.where(status: ACTIVE_VIDEO_STATUSES).exists?
      "This account has reached its daily upload limit." if recent_upload_count(user) >= daily_upload_limit
    end

    def max_upload_bytes
      positive_integer_setting("MAX_UPLOAD_BYTES", DEFAULT_MAX_UPLOAD_BYTES)
    end

    def daily_upload_limit
      positive_integer_setting("DAILY_UPLOAD_LIMIT", DEFAULT_DAILY_UPLOAD_LIMIT)
    end

    private

    def allowed_emails(value)
      value.split(",").filter_map do |email|
        normalized = email.strip.downcase
        normalized if normalized.present?
      end.to_set
    end

    def recent_upload_count(user)
      user.videos.where(created_at: 24.hours.ago..).count
    end

    def boolean_setting(name, default:)
      value = ENV[name]
      return default if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def positive_integer_setting(name, default)
      value = Integer(ENV.fetch(name, default), exception: false)
      value&.positive? ? value : default
    end
  end
end
