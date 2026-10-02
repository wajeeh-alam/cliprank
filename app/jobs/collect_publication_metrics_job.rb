class CollectPublicationMetricsJob < ApplicationJob
  queue_as :default
  retry_on Instagram::Client::RetryableError, Linkedin::Client::RetryableError,
    wait: :polynomially_longer, attempts: 5

  def perform(publication_id, instagram_client: nil, linkedin_client: nil, observed_at: Time.current)
    publication = Publication.find(publication_id)
    age = (observed_at - publication.published_at) / 1.hour
    return unless MetricSnapshot::MATURE_AGE_RANGE.cover?(age)

    source, raw = if publication.platform == "instagram"
      account = publication.user.instagram_accounts.find_by!(instagram_user_id: publication.platform_account_key)
      [ "instagram_api", (instagram_client || Instagram::Client.new).insights(
        access_token: account.access_token, instagram_media_id: publication.post_id
      ) ]
    else
      account = publication.user.linkedin_accounts.find_by!(linkedin_member_id: publication.platform_account_key)
      [ "linkedin_api", (linkedin_client || Linkedin::Client.new).analytics(
        access_token: account.access_token, linkedin_post_urn: publication.post_id
      ) ]
    end
    publication.metric_snapshots.create!(snapshot_attributes(publication, raw, source, observed_at))
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue ActiveRecord::RecordNotFound, Instagram::Client::UnsupportedInsightsError, Linkedin::Client::UnsupportedAnalyticsError => error
    Rails.logger.info("Publication metrics unavailable for #{publication_id}: #{error.class.name}")
    nil
  end

  private

  def snapshot_attributes(publication, raw, source, observed_at)
    normalized = raw.transform_keys(&:to_s)
    {
      observed_at: observed_at,
      source: source,
      source_record_id: "#{source}:#{publication.post_id}:#{observed_at.utc.iso8601}",
      # LinkedIn exposes impressions through the currently authorized endpoint,
      # not video views. Keep views missing instead of relabeling engagement.
      views: publication.platform == "instagram" ? integer_or_nil(normalized["views"]) : nil,
      likes: integer_or_nil(normalized[publication.platform == "instagram" ? "likes" : "reaction"]),
      comments: integer_or_nil(normalized[publication.platform == "instagram" ? "comments" : "comment"]),
      shares: integer_or_nil(normalized[publication.platform == "instagram" ? "shares" : "reshare"]),
      saves: integer_or_nil(normalized[publication.platform == "instagram" ? "saved" : "post_save"]),
      raw_metrics: normalized,
      demo_data: publication.demo_data
    }
  end

  def integer_or_nil(value)
    value.nil? ? nil : Integer(value)
  rescue ArgumentError, TypeError
    nil
  end
end
