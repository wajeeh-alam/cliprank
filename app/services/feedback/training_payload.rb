module Feedback
  class TrainingPayload
    LABEL_POLICY_VERSION = "views-72h-account-median-v1".freeze

    def self.call(platform:, schema_version: nil)
      publications = Publication.where(platform: platform)
      publications = if publications.where(demo_data: false).exists?
        publications.where(demo_data: false)
      else
        publications.where(demo_data: true)
      end
      publications = publications.includes(:metric_snapshots, ranking_prediction: { candidate_clip: :video })
        .order(:published_at, :id)
      publications = publications.joins(:ranking_prediction).where(ranking_predictions: { schema_version: schema_version }) if schema_version.present?

      {
        "platform" => platform,
        "feature_schema_version" => schema_version || publications.first&.ranking_prediction&.schema_version || "features-1",
        "label_policy_version" => LABEL_POLICY_VERSION,
        "maturity_min_hours" => MetricSnapshot::MATURE_AGE_RANGE.begin,
        "maturity_max_hours" => MetricSnapshot::MATURE_AGE_RANGE.end,
        "account_history_window" => 20,
        "minimum_account_history" => 5,
        "publications" => publications.map { |publication| publication_payload(publication) }
      }
    end

    def self.publication_payload(publication)
      prediction = publication.ranking_prediction
      {
        "publication_id" => publication.id.to_s,
        "account_id" => publication.platform_account_key,
        "source_video_id" => prediction.candidate_clip.video_id.to_s,
        "published_at" => publication.published_at.iso8601,
        "features" => prediction.frozen_features,
        "schema_version" => prediction.schema_version,
        "baseline_score" => prediction.baseline_score.to_f,
        "snapshots" => publication.metric_snapshots.order(:observed_at, :id).map do |snapshot|
          {
            "snapshot_id" => snapshot.id.to_s,
            "observed_at" => snapshot.observed_at.iso8601,
            "post_age_hours" => snapshot.post_age_hours.to_f,
            "views" => snapshot.views
          }
        end
      }
    end
    private_class_method :publication_payload
  end
end
