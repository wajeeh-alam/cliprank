class CreateExplanations < ActiveRecord::Migration[8.1]
  def change
    create_table :explanations do |t|
      t.references :candidate_score, null: false, foreign_key: { on_delete: :restrict }
      t.string :explanation_version, null: false
      t.text :summary, null: false
      t.jsonb :strengths, null: false, default: []
      t.jsonb :weaknesses, null: false, default: []
      t.jsonb :quantitative_facts, null: false, default: []
      t.string :model_version
      t.string :prompt_version

      t.timestamps
    end

    add_check_constraint :explanations, <<~SQL.squish, name: "explanations_bullet_payloads_arrays"
      jsonb_typeof(strengths) = 'array'
      AND jsonb_typeof(weaknesses) = 'array'
      AND jsonb_typeof(quantitative_facts) = 'array'
    SQL
    add_index :explanations, [ :candidate_score_id, :explanation_version ], unique: true, name: "index_explanations_on_score_and_version"
  end
end
