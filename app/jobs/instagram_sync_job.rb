class InstagramSyncJob < ApplicationJob
  queue_as :default
  retry_on Instagram::Client::RetryableError, wait: :polynomially_longer, attempts: 5

  def perform(instagram_account_id, client: nil, now: Time.current)
    account = InstagramAccount.find(instagram_account_id)
    client ||= Instagram::Client.new

    token = account.access_token
    if account.token_expiring_soon?(now)
      refreshed = client.refresh_access_token(access_token: token)
      token = refreshed.fetch("access_token")
      account.update!(access_token: token, token_expires_at: expires_at(refreshed, now))
    end

    media_payload = client.media(access_token: token, instagram_user_id: account.instagram_user_id)
    captured_at = now
    prepared_media = media_payload.map do |payload|
      validate_media_payload!(payload)
      metrics = begin
        client.insights(access_token: token, instagram_media_id: payload.fetch("id"))
      rescue Instagram::Client::UnsupportedInsightsError
        {}
      end
      [ payload, metrics ]
    end

    ActiveRecord::Base.transaction do
      account.lock!
      prepared_media.each do |payload, metrics|
        media = upsert_media(account, payload)
        if metrics.present?
          media.instagram_insight_snapshots.find_or_initialize_by(captured_on: captured_at.to_date).tap do |snapshot|
            snapshot.instagram_account = account
            snapshot.captured_at = captured_at
            snapshot.metrics = sanitize_metrics(metrics)
            snapshot.save!
          end
        end
      end
      account.update!(last_synced_at: captured_at, sync_error: nil)
    end
  rescue Instagram::Client::RetryableError => error
    record_sync_error(instagram_account_id, error)
    raise
  rescue Instagram::Client::Error => error
    record_sync_error(instagram_account_id, error)
  end

  private

  def validate_media_payload!(payload)
    valid = payload.is_a?(Hash) && payload["id"].to_s.present? && InstagramMedia::MEDIA_TYPES.include?(payload["media_type"].to_s)
    return if valid

    raise Instagram::Client::RequestError, "Instagram returned invalid media data"
  end

  def upsert_media(account, payload)
    attributes = payload
    media = account.instagram_media.find_or_initialize_by(instagram_media_id: attributes["id"].to_s)
    media.assign_attributes(
      media_type: attributes["media_type"].to_s,
      media_product_type: attributes["media_product_type"],
      permalink: attributes["permalink"],
      caption: attributes["caption"],
      published_at: parse_time(attributes["timestamp"]),
      like_count: integer_or_nil(attributes["like_count"]),
      comments_count: integer_or_nil(attributes["comments_count"]),
      metadata: attributes.slice(*Instagram::Client::MEDIA_FIELDS).except("id", "caption", "media_type", "media_product_type", "permalink", "timestamp", "like_count", "comments_count")
    )
    media.save!
    media
  end

  def sanitize_metrics(metrics)
    return {} unless metrics.is_a?(Hash)

    metrics.each_with_object({}) do |(key, value), result|
      next if key.to_s.downcase.match?(/token|secret|password|credential|authorization/)
      next unless value.is_a?(Numeric) || value.is_a?(String) || value == true || value == false || value.nil?

      result[key.to_s] = value
    end
  end

  def expires_at(payload, now)
    seconds = payload["expires_in"].to_i
    seconds.positive? ? now + seconds.seconds : nil
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end

  def integer_or_nil(value)
    value.present? ? Integer(value) : nil
  rescue ArgumentError, TypeError
    nil
  end

  def record_sync_error(account_id, error)
    account = InstagramAccount.find_by(id: account_id)
    return unless account

    account.update_columns(sync_error: error.message.to_s.first(500), updated_at: Time.current)
  end
end
