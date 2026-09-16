class CreateTitleIdeas < ActiveRecord::Migration[8.1]
  def change
    create_table :title_ideas do |t|
      t.references :title_idea_set, null: false, foreign_key: { on_delete: :cascade }
      t.integer :rank, null: false
      t.string :title, null: false
      t.string :angle, null: false
      t.jsonb :evidence, null: false, default: {}
      t.timestamps

      t.index [ :title_idea_set_id, :rank ], unique: true,
        name: "index_title_ideas_on_set_and_rank"
      t.check_constraint "rank >= 1", name: "title_ideas_rank_positive"
      t.check_constraint "char_length(title) >= 1", name: "title_ideas_title_non_empty"
      t.check_constraint "jsonb_typeof(evidence) = 'object'",
        name: "title_ideas_evidence_object"
    end
  end
end
