class CreateCandidateScores < ActiveRecord::Migration[8.1]
  def change
    create_table :candidate_scores do |t|
      t.references :ranking_run, null: false, foreign_key: { on_delete: :restrict }
      t.references :candidate_clip, null: false, foreign_key: { on_delete: :restrict }
      t.integer :rank, null: false
      t.decimal :clip_score, precision: 5, scale: 2, null: false
      t.decimal :content_quality, precision: 5, scale: 2, null: false
      t.decimal :hook, precision: 5, scale: 2, null: false
      t.decimal :delivery, precision: 5, scale: 2, null: false
      t.decimal :pacing, precision: 5, scale: 2, null: false
      t.decimal :visual_engagement, precision: 5, scale: 2, null: false
      t.decimal :standalone_clarity, precision: 5, scale: 2, null: false
      t.jsonb :component_details, null: false, default: {}

      t.timestamps
    end

    score_columns = %w[clip_score content_quality hook delivery pacing visual_engagement standalone_clarity]
    score_columns.each do |column|
      add_check_constraint :candidate_scores, "#{column} BETWEEN 0 AND 100", name: "candidate_scores_#{column}_range"
    end
    add_check_constraint :candidate_scores, "rank >= 1", name: "candidate_scores_rank_positive"
    add_check_constraint :candidate_scores, "jsonb_typeof(component_details) = 'object'", name: "candidate_scores_component_details_object"
    add_index :candidate_scores, [ :ranking_run_id, :candidate_clip_id ], unique: true, name: "index_candidate_scores_on_run_and_candidate"
    add_index :candidate_scores, [ :ranking_run_id, :rank ], unique: true, name: "index_candidate_scores_on_run_and_rank"
    add_index :candidate_scores, [ :candidate_clip_id, :created_at ], order: { created_at: :desc }
  end
end
