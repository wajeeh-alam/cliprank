class CreateTranscriptSegments < ActiveRecord::Migration[8.1]
  def change
    create_table :transcript_segments do |t|
      t.references :video, null: false, foreign_key: { on_delete: :restrict }
      t.integer :sequence, null: false
      t.bigint :start_ms, null: false
      t.bigint :end_ms, null: false
      t.text :text, null: false
      t.jsonb :words, null: false, default: []
      t.boolean :is_sentence_boundary_start, null: false, default: false
      t.boolean :is_sentence_boundary_end, null: false, default: false
      t.string :transcript_version, null: false

      t.timestamps
    end

    add_check_constraint :transcript_segments, "sequence >= 0", name: "transcript_segments_sequence_non_negative"
    add_check_constraint :transcript_segments, "start_ms >= 0 AND start_ms < end_ms", name: "transcript_segments_timestamp_range"
    add_check_constraint :transcript_segments, "jsonb_typeof(words) = 'array'", name: "transcript_segments_words_array"
    add_index :transcript_segments, [ :video_id, :transcript_version, :sequence ], unique: true, name: "index_transcript_segments_on_video_version_sequence"
    add_index :transcript_segments, [ :video_id, :start_ms ]
    add_index :transcript_segments, [ :video_id, :end_ms ]
  end
end
