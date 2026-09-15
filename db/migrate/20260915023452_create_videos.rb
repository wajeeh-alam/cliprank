class CreateVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :videos do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.string :title, null: false
      t.string :status, null: false, default: "uploading"
      t.bigint :duration_ms
      t.string :source_media_checksum
      t.string :processing_error_code
      t.text :processing_error_message
      t.jsonb :processing_error_details, null: false, default: {}
      t.string :pipeline_version, null: false, default: "phase1"
      t.datetime :completed_at

      t.timestamps
    end

    add_check_constraint :videos, "duration_ms IS NULL OR duration_ms >= 0", name: "videos_duration_non_negative"
    add_check_constraint :videos, <<~SQL.squish, name: "videos_status_valid"
      status IN ('uploading', 'extracting_audio', 'transcribing', 'generating_candidates',
                 'extracting_features', 'ranking', 'generating_previews', 'complete', 'failed')
    SQL
    add_check_constraint :videos, "jsonb_typeof(processing_error_details) = 'object'", name: "videos_error_details_object"
    add_index :videos, [ :user_id, :created_at ], order: { created_at: :desc }
    add_index :videos, [ :user_id, :status ]
    add_index :videos, :source_media_checksum
  end
end
