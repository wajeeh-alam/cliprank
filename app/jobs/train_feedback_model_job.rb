require "digest"

class TrainFeedbackModelJob < ApplicationJob
  queue_as :default
  retry_on Ml::Client::RetryableError, wait: :polynomially_longer, attempts: 5

  def perform(platform = "instagram", client: nil)
    schema_version = ENV.fetch("ML_FEATURE_VERSION", "features-1")
    payload = Feedback::TrainingPayload.call(platform: platform, schema_version: schema_version)
    return if unchanged_dataset?(platform, schema_version, payload)

    request_digest = dataset_key(payload)
    response = (client || Ml::Client.new).train_feedback(
      payload,
      request_id: "feedback-train-#{platform}-#{SecureRandom.hex(8)}",
      idempotency_key: "feedback/train/#{platform}/#{request_digest}"
    )
    response.fetch("dataset_manifest")["request_sha256"] = request_digest
    ModelVersion.find_or_create_by!(version: response.fetch("model_version")) do |model|
      model.assign_attributes(
        platform: platform,
        feature_schema_version: schema_version,
        label_policy_version: payload.fetch("label_policy_version"),
        algorithm: response.fetch("algorithm"),
        artifact: response.fetch("artifact"),
        artifact_sha256: response.fetch("artifact_sha256"),
        artifact_location: "database:model_versions/#{response.fetch('model_version')}/artifact",
        training_cutoff: Time.zone.parse(response.fetch("training_cutoff")),
        sample_count: response.fetch("sample_count"),
        evaluation_metrics: response.fetch("evaluation_metrics"),
        dataset_manifest: response.fetch("dataset_manifest"),
        status: "shadow",
        trained_at: Time.current,
        demo_data: Publication.where(platform: platform).where.not(demo_data: true).none?
      )
    end
  rescue Ml::Client::Error => error
    raise if error.retryable

    Rails.logger.info("Feedback training remained unavailable: #{error.code || error.class.name}")
    nil
  end

  private

  def unchanged_dataset?(platform, schema_version, payload)
    latest = ModelVersion.where(platform: platform, feature_schema_version: schema_version).order(created_at: :desc).first
    return false unless latest

    latest.dataset_manifest["request_sha256"].present? && latest.dataset_manifest["request_sha256"] == dataset_key(payload)
  end

  def dataset_key(payload)
    rows = payload.fetch("publications").map do |publication|
      [ publication.fetch("publication_id"), publication.fetch("snapshots").map { |snapshot| snapshot.fetch("snapshot_id") } ]
    end
    Digest::SHA256.hexdigest(JSON.generate(rows))
  end
end
