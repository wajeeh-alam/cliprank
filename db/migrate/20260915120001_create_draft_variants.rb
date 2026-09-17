class CreateDraftVariants < ActiveRecord::Migration[8.1]
  def change
    create_table :draft_variants do |t|
      t.references :publishing_draft, null: false, foreign_key: { on_delete: :cascade }
      t.string :platform, null: false
      t.string :title, null: false
      t.text :description, null: false
      t.jsonb :hashtags, null: false, default: []
      t.text :cta
      t.jsonb :evidence, null: false, default: {}
      t.timestamps

      t.index [ :publishing_draft_id, :platform ], unique: true
      t.check_constraint "platform IN ('instagram', 'linkedin')", name: "draft_variants_platform_valid"
      t.check_constraint "jsonb_typeof(hashtags) = 'array'", name: "draft_variants_hashtags_array"
      t.check_constraint "jsonb_typeof(evidence) = 'object'", name: "draft_variants_evidence_object"
    end
  end
end
