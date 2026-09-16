class AddTitleIdeasVersionToRankingRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :ranking_runs, :title_ideas_version, :string
  end
end
