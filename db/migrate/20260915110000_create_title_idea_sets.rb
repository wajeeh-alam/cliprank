class CreateTitleIdeaSets < ActiveRecord::Migration[8.1]
  def change
    create_table :title_idea_sets do |t|
      t.references :ranking_run, null: false, foreign_key: { on_delete: :cascade }
      t.references :candidate_clip, null: false, foreign_key: { on_delete: :cascade }
      t.string :version, null: false
      t.string :source_type, null: false
      t.integer :sample_size, null: false, default: 0
      t.jsonb :evidence, null: false, default: {}
      t.timestamps

      t.index [ :ranking_run_id, :candidate_clip_id, :version ], unique: true,
        name: "index_title_idea_sets_on_run_candidate_version"
      t.check_constraint "source_type IN ('transcript', 'instagram_history')",
        name: "title_idea_sets_source_type_valid"
      t.check_constraint "sample_size >= 0", name: "title_idea_sets_sample_size_non_negative"
      t.check_constraint "jsonb_typeof(evidence) = 'object'",
        name: "title_idea_sets_evidence_object"
    end
  end
end
