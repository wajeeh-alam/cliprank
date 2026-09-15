class CreateCandidateClips < ActiveRecord::Migration[8.1]
  def change
    create_table :candidate_clips do |t|
      t.references :video, null: false, foreign_key: { on_delete: :restrict }
      t.integer :sequence, null: false
      t.bigint :start_ms, null: false
      t.bigint :end_ms, null: false
      t.bigint :duration_ms, null: false
      t.text :transcript, null: false
      t.string :status, null: false, default: "pending"
      t.string :generation_version, null: false
      t.bigint :recommended_start_ms
      t.bigint :recommended_end_ms
      t.text :trim_reason
      t.string :processing_error_code
      t.text :processing_error_message

      t.timestamps
    end

    add_check_constraint :candidate_clips, "sequence >= 0", name: "candidate_clips_sequence_non_negative"
    add_check_constraint :candidate_clips, "start_ms >= 0 AND start_ms < end_ms", name: "candidate_clips_timestamp_range"
    add_check_constraint :candidate_clips, "duration_ms = end_ms - start_ms AND duration_ms BETWEEN 15000 AND 60000", name: "candidate_clips_duration_range"
    add_check_constraint :candidate_clips, <<~SQL.squish, name: "candidate_clips_recommended_range"
      (recommended_start_ms IS NULL AND recommended_end_ms IS NULL)
      OR (recommended_start_ms >= 0 AND recommended_start_ms < recommended_end_ms)
    SQL
    add_check_constraint :candidate_clips, "status IN ('pending', 'analyzing', 'ranked', 'rendering', 'ready', 'failed', 'rejected')", name: "candidate_clips_status_valid"
    add_index :candidate_clips, [ :video_id, :sequence ]
    add_index :candidate_clips, [ :video_id, :status ]
    add_index :candidate_clips, [ :video_id, :start_ms ]
    add_index :candidate_clips, [ :video_id, :end_ms ]
    add_index :candidate_clips, [ :video_id, :generation_version, :start_ms, :end_ms ], unique: true, name: "index_candidate_clips_on_generation_boundaries"
  end
end
