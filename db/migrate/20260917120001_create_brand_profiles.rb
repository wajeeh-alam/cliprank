class CreateBrandProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :brand_profiles do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :brand_name, null: false
      t.text :description, null: false
      t.text :audience, null: false
      t.text :voice, null: false
      t.jsonb :content_pillars, null: false, default: []
      t.jsonb :preferred_terms, null: false, default: []
      t.jsonb :avoided_terms, null: false, default: []
      t.text :default_cta, null: false, default: ""
      t.jsonb :example_posts, null: false, default: []
      t.timestamps

      t.check_constraint "jsonb_typeof(content_pillars) = 'array'", name: "brand_profiles_content_pillars_array"
      t.check_constraint "jsonb_typeof(preferred_terms) = 'array'", name: "brand_profiles_preferred_terms_array"
      t.check_constraint "jsonb_typeof(avoided_terms) = 'array'", name: "brand_profiles_avoided_terms_array"
      t.check_constraint "jsonb_typeof(example_posts) = 'array'", name: "brand_profiles_example_posts_array"
    end
  end
end
