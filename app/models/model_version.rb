class ModelVersion < ApplicationRecord
  PLATFORMS = %w[instagram linkedin].freeze
  STATUSES = %w[shadow active retired rejected failed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  has_many :ranking_predictions, dependent: :nullify

  validates :version, :platform, :feature_schema_version, :label_policy_version,
    :algorithm, :artifact_sha256, :artifact_location, :training_cutoff, :trained_at, presence: true
  validates :version, uniqueness: true
  validates :platform, inclusion: { in: PLATFORMS }
  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :artifact, :evaluation_metrics, :dataset_manifest, hash_payload: true

  scope :for_platform, ->(platform) { where(platform: platform) }

  def self.deployed_for(platform:, schema_version:)
    active.find_by(platform: platform, feature_schema_version: schema_version)
  end

  def activate!
    transaction do
      self.class.lock.where(platform: platform, feature_schema_version: feature_schema_version, status: "active")
        .where.not(id: id).find_each do |current|
          current.update!(status: "retired", retired_at: Time.current)
        end
      update!(status: "active", activated_at: Time.current, retired_at: nil)
    end
  end

  def retire!
    update!(status: "retired", retired_at: Time.current)
  end
end
