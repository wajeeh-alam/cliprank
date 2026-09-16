class CreateInstagramInsightSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_insight_snapshots do |t|
      t.references :instagram_account, null: false, foreign_key: { on_delete: :cascade }
      t.references :instagram_media, null: false, foreign_key: { on_delete: :cascade }
      t.date :captured_on, null: false
      t.datetime :captured_at, null: false
      t.jsonb :metrics, null: false, default: {}
      t.timestamps

      t.index [ :instagram_media_id, :captured_on ], unique: true,
        name: "index_instagram_insights_on_media_and_captured_on"
      t.index [ :instagram_account_id, :captured_on ],
        name: "index_instagram_insights_on_account_and_captured_on"
      t.check_constraint "jsonb_typeof(metrics) = 'object'",
        name: "instagram_insight_snapshots_metrics_object"
    end
  end
end
