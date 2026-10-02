require "test_helper"

class ModelVersionTest < ActiveSupport::TestCase
  def build_model(version, status: "shadow")
    ModelVersion.create!(
      version: version,
      platform: "instagram",
      feature_schema_version: "features-1",
      label_policy_version: "labels-1",
      algorithm: "ridge",
      artifact: { "artifact_version" => "1" },
      artifact_sha256: "a" * 64,
      artifact_location: "database:#{version}",
      training_cutoff: 1.day.ago,
      sample_count: 40,
      evaluation_metrics: { "release_gate" => { "eligible" => true } },
      dataset_manifest: {},
      status: status,
      trained_at: Time.current
    )
  end

  test "activation atomically retires the prior deployment and supports rollback" do
    first = build_model("feedback-1")
    second = build_model("feedback-2")

    first.activate!
    assert first.reload.active?
    second.activate!
    assert second.reload.active?
    assert first.reload.retired?

    first.activate!
    assert first.reload.active?
    assert second.reload.retired?
  end
end
