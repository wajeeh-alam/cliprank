class CreateLinkedinAnalytics < ActiveRecord::Migration[8.1]
  def change
    create_table :linkedin_accounts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.string :linkedin_member_id, null: false
      t.string :display_name, null: false
      t.text :access_token_ciphertext, null: false
      t.datetime :token_expires_at
      t.datetime :last_synced_at
      t.string :sync_error
      t.timestamps

      t.index [ :user_id, :linkedin_member_id ], unique: true,
        name: "index_linkedin_accounts_on_user_and_member"
      t.index :linkedin_member_id, unique: true
    end

    create_table :linkedin_posts do |t|
      t.references :linkedin_account, null: false, foreign_key: { on_delete: :cascade }
      t.string :linkedin_post_urn, null: false
      t.text :commentary
      t.string :content_type
      t.string :permalink
      t.datetime :published_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index [ :linkedin_account_id, :linkedin_post_urn ], unique: true,
        name: "index_linkedin_posts_on_account_and_urn"
      t.check_constraint "jsonb_typeof(metadata) = 'object'",
        name: "linkedin_posts_metadata_object"
    end

    create_table :linkedin_insight_snapshots do |t|
      t.references :linkedin_account, null: false, foreign_key: { on_delete: :cascade }
      t.references :linkedin_post, null: false, foreign_key: { on_delete: :cascade }
      t.date :captured_on, null: false
      t.datetime :captured_at, null: false
      t.jsonb :metrics, null: false, default: {}
      t.timestamps

      t.index [ :linkedin_post_id, :captured_on ], unique: true,
        name: "index_linkedin_insights_on_post_and_captured_on"
      t.index [ :linkedin_account_id, :captured_on ],
        name: "index_linkedin_insights_on_account_and_captured_on"
      t.check_constraint "jsonb_typeof(metrics) = 'object'",
        name: "linkedin_insight_snapshots_metrics_object"
    end
  end
end
