class CreateRankingRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :ranking_runs do |t|
      t.references :video, null: false, foreign_key: { on_delete: :restrict }
      t.string :feature_version, null: false
      t.string :scorer_version, null: false
      t.jsonb :config, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.string :error_code
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_check_constraint :ranking_runs, "jsonb_typeof(config) = 'object'", name: "ranking_runs_config_object"
    add_check_constraint :ranking_runs, "status IN ('pending', 'running', 'succeeded', 'failed')", name: "ranking_runs_status_valid"
    add_index :ranking_runs, [ :video_id, :created_at ], order: { created_at: :desc }
  end
end
