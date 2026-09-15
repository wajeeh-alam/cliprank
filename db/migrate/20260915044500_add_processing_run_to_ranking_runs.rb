class AddProcessingRunToRankingRuns < ActiveRecord::Migration[8.1]
  def change
    add_reference :ranking_runs, :processing_run, null: false, foreign_key: { on_delete: :restrict }
    add_index :ranking_runs, [ :processing_run_id, :feature_version, :scorer_version ],
      unique: true, name: "index_ranking_runs_on_processing_and_versions"
  end
end
