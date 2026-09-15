class CreateExports < ActiveRecord::Migration[8.1]
  def change
    create_table :exports do |t|
      t.references :candidate_clip, null: false, foreign_key: { on_delete: :restrict }
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.bigint :start_ms, null: false
      t.bigint :end_ms, null: false
      t.string :status, null: false, default: "requested"
      t.string :error_code
      t.text :error_message
      t.string :export_version, null: false

      t.timestamps
    end

    add_check_constraint :exports, "start_ms >= 0 AND start_ms < end_ms", name: "exports_timestamp_range"
    add_check_constraint :exports, "status IN ('requested', 'rendering', 'ready', 'failed')", name: "exports_status_valid"
    add_index :exports, [ :user_id, :created_at ], order: { created_at: :desc }
    add_index :exports, [ :candidate_clip_id, :created_at ], order: { created_at: :desc }
  end
end
