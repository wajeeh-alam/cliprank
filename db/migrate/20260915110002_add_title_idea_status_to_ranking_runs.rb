class AddTitleIdeaStatusToRankingRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :ranking_runs, :title_ideas_status, :string, null: false, default: "pending"
    add_column :ranking_runs, :title_ideas_error, :string
    add_check_constraint :ranking_runs,
      "title_ideas_status IN ('pending', 'generating', 'succeeded', 'failed')",
      name: "ranking_runs_title_ideas_status_valid"
  end
end
