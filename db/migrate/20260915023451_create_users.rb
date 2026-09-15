class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :name
      t.string :password_digest

      t.timestamps
    end

    add_check_constraint :users, "char_length(btrim(email)) > 0", name: "users_email_not_blank"
    add_index :users, "lower(email)", unique: true, name: "index_users_on_lower_email"
  end
end
