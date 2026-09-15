class CreateProcessingRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :processing_runs do |t|
      t.references :video, null: false, foreign_key: { on_delete: :restrict }
      t.string :pipeline_version, null: false
      t.string :idempotency_key, null: false
      t.string :status, null: false, default: "pending"
      t.string :current_stage
      t.integer :attempt_count, null: false, default: 0
      t.string :error_code
      t.text :error_message
      t.jsonb :error_details, null: false, default: {}
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_check_constraint :processing_runs, "attempt_count >= 0", name: "processing_runs_attempt_count_non_negative"
    add_check_constraint :processing_runs, "status IN ('pending', 'running', 'succeeded', 'failed')", name: "processing_runs_status_valid"
    add_check_constraint :processing_runs, "jsonb_typeof(error_details) = 'object'", name: "processing_runs_error_details_object"
    add_index :processing_runs, :idempotency_key, unique: true
    add_index :processing_runs, [ :video_id, :pipeline_version, :status ]
  end
end
