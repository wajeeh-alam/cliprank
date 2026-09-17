class LinkedinSyncJob < ApplicationJob
  queue_as :default
  retry_on Linkedin::Client::RetryableError, wait: :polynomially_longer, attempts: 5

  def perform(linkedin_account_id, client: nil, now: Time.current)
    account = LinkedinAccount.find(linkedin_account_id)
    client ||= Linkedin::Client.new
    raise Linkedin::Client::RequestError, "LinkedIn authorization has expired" if account.token_expired?(now)

    token = account.access_token
    prepared_posts = client.posts(access_token: token, linkedin_member_id: account.linkedin_member_id).map do |payload|
      validate_post_payload!(payload)
      metrics = begin
        client.analytics(access_token: token, linkedin_post_urn: payload.fetch("id"))
      rescue Linkedin::Client::UnsupportedAnalyticsError
        {}
      end
      [ payload, metrics ]
    end

    ActiveRecord::Base.transaction do
      account.lock!
      prepared_posts.each do |payload, metrics|
        post = upsert_post(account, payload)
        next if metrics.empty?

        post.linkedin_insight_snapshots.find_or_initialize_by(captured_on: now.to_date).tap do |snapshot|
          snapshot.linkedin_account = account
          snapshot.captured_at = now
          snapshot.metrics = sanitize_metrics(metrics)
          snapshot.save!
        end
      end
      account.update!(last_synced_at: now, sync_error: nil)
    end
  rescue Linkedin::Client::RetryableError => error
    record_sync_error(linkedin_account_id, error)
    raise
  rescue Linkedin::Client::Error => error
    record_sync_error(linkedin_account_id, error)
  end

  private

  def validate_post_payload!(payload)
    valid = payload.is_a?(Hash) && payload["id"].to_s.match?(/\Aurn:li:(?:share|ugcPost):[^\s]+\z/)
    return if valid

    raise Linkedin::Client::RequestError, "LinkedIn returned invalid post data"
  end

  def upsert_post(account, payload)
    post = account.linkedin_posts.find_or_initialize_by(linkedin_post_urn: payload.fetch("id"))
    post.assign_attributes(
      commentary: payload["commentary"],
      content_type: content_type(payload["content"]),
      permalink: payload["permalink"],
      published_at: time_from_milliseconds(payload["publishedAt"] || payload["createdAt"]),
      metadata: payload.slice("author", "visibility", "lifecycleState", "content", "distribution")
    )
    post.save!
    post
  end

  def content_type(content)
    return "text" unless content.is_a?(Hash) && content.present?

    %w[video media multiImage document article poll].find { |key| content.key?(key) } || content.keys.first.to_s
  end

  def time_from_milliseconds(value)
    milliseconds = Integer(value)
    Time.zone.at(milliseconds / 1000.0)
  rescue ArgumentError, TypeError
    nil
  end

  def sanitize_metrics(metrics)
    metrics.each_with_object({}) do |(key, value), result|
      next if key.to_s.downcase.match?(/token|secret|password|credential|authorization/)
      next unless value.is_a?(Numeric) || value.is_a?(String) || value == true || value == false || value.nil?

      result[key.to_s] = value
    end
  end

  def record_sync_error(account_id, error)
    account = LinkedinAccount.find_by(id: account_id)
    return unless account

    account.update_columns(sync_error: error.message.to_s.first(500), updated_at: Time.current)
  end
end
