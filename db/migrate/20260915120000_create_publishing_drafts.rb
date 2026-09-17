class CreatePublishingDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :publishing_drafts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.references :video, null: false, foreign_key: { on_delete: :restrict }
      t.references :candidate_clip, null: false, foreign_key: { on_delete: :restrict }
      t.string :status, null: false, default: "draft"
      t.string :generator_version
      t.datetime :generated_at
      t.string :approved_payload_digest
      t.datetime :approved_at
      t.datetime :published_at
      t.text :error_message
      t.timestamps

      t.index [ :user_id, :created_at ], order: { created_at: :desc }
      t.index [ :user_id, :status ]
      t.index [ :candidate_clip_id, :created_at ], order: { created_at: :desc }
      t.check_constraint "status IN ('draft', 'ready_for_review', 'approved', 'publishing', 'published', 'failed')",
        name: "publishing_drafts_status_valid"
    end
  end
end
