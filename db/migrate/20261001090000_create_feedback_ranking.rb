class CreateFeedbackRanking < ActiveRecord::Migration[8.1]
  def change
    create_table :model_versions do |t|
      t.string :version, null: false
      t.string :platform, null: false
      t.string :feature_schema_version, null: false
      t.string :label_policy_version, null: false
      t.string :algorithm, null: false
      t.jsonb :artifact, null: false, default: {}
      t.string :artifact_sha256, null: false
      t.string :artifact_location, null: false
      t.datetime :training_cutoff, null: false
      t.integer :sample_count, null: false
      t.jsonb :evaluation_metrics, null: false, default: {}
      t.jsonb :dataset_manifest, null: false, default: {}
      t.string :status, null: false, default: "shadow"
      t.datetime :trained_at, null: false
      t.datetime :activated_at
      t.datetime :retired_at
      t.boolean :demo_data, null: false, default: false
      t.timestamps

      t.index :version, unique: true
      t.index [ :platform, :feature_schema_version, :created_at ],
        name: "index_model_versions_on_platform_schema_created"
      t.index [ :platform, :feature_schema_version ], unique: true,
        where: "status = 'active'", name: "index_one_active_feedback_model"
      t.check_constraint "platform IN ('instagram', 'linkedin')", name: "model_versions_platform_valid"
      t.check_constraint "status IN ('shadow', 'active', 'retired', 'rejected', 'failed')",
        name: "model_versions_status_valid"
      t.check_constraint "sample_count >= 0", name: "model_versions_sample_count_non_negative"
      t.check_constraint "jsonb_typeof(artifact) = 'object'", name: "model_versions_artifact_object"
      t.check_constraint "jsonb_typeof(evaluation_metrics) = 'object'", name: "model_versions_evaluation_object"
      t.check_constraint "jsonb_typeof(dataset_manifest) = 'object'", name: "model_versions_manifest_object"
    end

    create_table :ranking_predictions do |t|
      t.references :ranking_run, null: false, foreign_key: { on_delete: :restrict }
      t.references :candidate_clip, null: false, foreign_key: { on_delete: :restrict }
      t.references :model_version, null: true, foreign_key: { on_delete: :nullify }
      t.jsonb :frozen_features, null: false, default: {}
      t.string :schema_version, null: false
      t.string :feature_model_version, null: false
      t.decimal :baseline_score, precision: 7, scale: 4, null: false
      t.integer :baseline_rank, null: false
      t.decimal :feedback_score, precision: 12, scale: 6
      t.decimal :feedback_display_score, precision: 7, scale: 4
      t.integer :feedback_rank
      t.jsonb :model_contributions, null: false, default: []
      t.string :selected_scorer, null: false, default: "heuristic-1"
      t.string :fallback_reason
      t.datetime :recommended_at, null: false
      t.timestamps

      t.index [ :ranking_run_id, :candidate_clip_id ], unique: true,
        name: "index_ranking_predictions_on_run_and_candidate"
      t.index [ :candidate_clip_id, :recommended_at ],
        name: "index_ranking_predictions_on_candidate_recommended"
      t.check_constraint "baseline_score BETWEEN 0 AND 100", name: "ranking_predictions_baseline_score_range"
      t.check_constraint "baseline_rank >= 1", name: "ranking_predictions_baseline_rank_positive"
      t.check_constraint "feedback_display_score IS NULL OR feedback_display_score BETWEEN 0 AND 100",
        name: "ranking_predictions_feedback_display_score_range"
      t.check_constraint "feedback_rank IS NULL OR feedback_rank >= 1", name: "ranking_predictions_feedback_rank_positive"
      t.check_constraint "jsonb_typeof(frozen_features) = 'object'", name: "ranking_predictions_features_object"
      t.check_constraint "jsonb_typeof(model_contributions) = 'array'", name: "ranking_predictions_contributions_array"
    end

    create_table :publications do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.references :candidate_clip, null: false, foreign_key: { on_delete: :restrict }
      t.references :ranking_prediction, null: false, foreign_key: { on_delete: :restrict }
      t.string :platform, null: false
      t.string :platform_account_key, null: false
      t.string :post_id, null: false
      t.string :post_url
      t.datetime :published_at, null: false
      t.string :source, null: false, default: "manual"
      t.boolean :demo_data, null: false, default: false
      t.timestamps

      t.index [ :platform, :platform_account_key, :post_id ], unique: true,
        name: "index_publications_on_external_identity"
      t.index [ :user_id, :published_at ], order: { published_at: :desc }
      t.index [ :platform, :published_at ]
      t.check_constraint "platform IN ('instagram', 'linkedin')", name: "publications_platform_valid"
      t.check_constraint "source IN ('manual', 'csv', 'collector', 'fixture')", name: "publications_source_valid"
    end

    create_table :metric_snapshots do |t|
      t.references :publication, null: false, foreign_key: { on_delete: :restrict }
      t.datetime :observed_at, null: false
      t.datetime :imported_at, null: false
      t.decimal :post_age_hours, precision: 10, scale: 4, null: false
      t.bigint :views
      t.bigint :likes
      t.bigint :comments
      t.bigint :shares
      t.bigint :saves
      t.decimal :average_watch_time_seconds, precision: 12, scale: 4
      t.decimal :retention_rate, precision: 7, scale: 6
      t.string :source, null: false
      t.string :source_record_id
      t.string :import_fingerprint, null: false
      t.jsonb :raw_metrics, null: false, default: {}
      t.boolean :demo_data, null: false, default: false
      t.timestamps

      t.index :import_fingerprint, unique: true
      t.index [ :publication_id, :observed_at ]
      t.check_constraint "post_age_hours >= 0", name: "metric_snapshots_age_non_negative"
      %w[views likes comments shares saves].each do |metric|
        t.check_constraint "#{metric} IS NULL OR #{metric} >= 0", name: "metric_snapshots_#{metric}_non_negative"
      end
      t.check_constraint "average_watch_time_seconds IS NULL OR average_watch_time_seconds >= 0",
        name: "metric_snapshots_watch_time_non_negative"
      t.check_constraint "retention_rate IS NULL OR retention_rate BETWEEN 0 AND 1",
        name: "metric_snapshots_retention_rate_range"
      t.check_constraint "source IN ('manual', 'csv', 'instagram_api', 'linkedin_api', 'fixture')",
        name: "metric_snapshots_source_valid"
      t.check_constraint "jsonb_typeof(raw_metrics) = 'object'", name: "metric_snapshots_raw_metrics_object"
    end
  end
end
