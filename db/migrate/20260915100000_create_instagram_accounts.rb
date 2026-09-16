class CreateInstagramAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_accounts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.string :instagram_user_id, null: false
      t.string :username, null: false
      t.string :account_type, null: false
      t.text :access_token_ciphertext, null: false
      t.datetime :token_expires_at
      t.datetime :last_synced_at
      t.string :sync_error
      t.timestamps

      t.index [ :user_id, :instagram_user_id ], unique: true,
        name: "index_instagram_accounts_on_user_and_instagram_user"
      t.index :instagram_user_id, unique: true
      t.check_constraint "account_type IN ('BUSINESS', 'CREATOR')",
        name: "instagram_accounts_account_type_valid"
    end
  end
end
