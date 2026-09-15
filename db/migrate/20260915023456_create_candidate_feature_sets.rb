class CreateCandidateFeatureSets < ActiveRecord::Migration[8.1]
  def change
    create_table :candidate_feature_sets do |t|
      t.references :candidate_clip, null: false, foreign_key: { on_delete: :restrict }
      t.string :feature_version, null: false
      t.string :model_version
      t.string :prompt_version
      t.jsonb :semantic_features, null: false, default: {}
      t.jsonb :audio_features, null: false, default: {}
      t.jsonb :visual_features, null: false, default: {}
      t.jsonb :structural_features, null: false, default: {}
      t.jsonb :raw_metadata, null: false, default: {}

      t.timestamps
    end

    add_check_constraint :candidate_feature_sets, <<~SQL.squish, name: "candidate_feature_sets_payloads_objects"
      jsonb_typeof(semantic_features) = 'object'
      AND jsonb_typeof(audio_features) = 'object'
      AND jsonb_typeof(visual_features) = 'object'
      AND jsonb_typeof(structural_features) = 'object'
      AND jsonb_typeof(raw_metadata) = 'object'
    SQL
    add_index :candidate_feature_sets, [ :candidate_clip_id, :feature_version ], unique: true, name: "index_candidate_feature_sets_on_candidate_and_version"
    add_index :candidate_feature_sets, [ :feature_version, :created_at ]
  end
end
