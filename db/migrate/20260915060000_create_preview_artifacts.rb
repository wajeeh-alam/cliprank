class CreatePreviewArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_artifacts do |t|
      t.references :ranking_run, null: false, foreign_key: { on_delete: :restrict }
      t.references :candidate_clip, null: false, foreign_key: { on_delete: :restrict }
      t.string :kind, null: false
      t.string :render_version, null: false
      t.string :status, null: false, default: "requested"
      t.bigint :start_ms, null: false
      t.bigint :end_ms, null: false
      t.bigint :duration_ms, null: false
      t.string :error_code
      t.text :error_message
      t.timestamps
    end

    add_index :preview_artifacts, [ :ranking_run_id, :candidate_clip_id, :kind, :render_version ],
      unique: true, name: "index_preview_artifacts_on_run_candidate_kind_version"
    add_index :preview_artifacts, [ :ranking_run_id, :status ]
    add_check_constraint :preview_artifacts, "kind IN ('preview', 'thumbnail')", name: "preview_artifacts_kind_valid"
    add_check_constraint :preview_artifacts, "status IN ('requested', 'rendering', 'ready', 'failed')", name: "preview_artifacts_status_valid"
    add_check_constraint :preview_artifacts, "start_ms >= 0 AND start_ms < end_ms AND duration_ms = end_ms - start_ms", name: "preview_artifacts_timestamp_range"
  end
end
