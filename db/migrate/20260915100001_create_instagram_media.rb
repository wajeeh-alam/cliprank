class CreateInstagramMedia < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_media do |t|
      t.references :instagram_account, null: false, foreign_key: { on_delete: :cascade }
      t.string :instagram_media_id, null: false
      t.string :media_type, null: false
      t.string :media_product_type
      t.string :permalink
      t.text :caption
      t.datetime :published_at
      t.integer :like_count
      t.integer :comments_count
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index [ :instagram_account_id, :instagram_media_id ], unique: true,
        name: "index_instagram_media_on_account_and_instagram_media"
      t.check_constraint "jsonb_typeof(metadata) = 'object'",
        name: "instagram_media_metadata_object"
    end
  end
end
