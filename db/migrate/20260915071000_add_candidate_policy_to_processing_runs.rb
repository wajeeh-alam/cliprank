class AddCandidatePolicyToProcessingRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :processing_runs, :candidate_generation_version, :string
    add_column :processing_runs, :candidate_processing_mode, :string
    add_check_constraint :processing_runs,
      "candidate_processing_mode IS NULL OR candidate_processing_mode IN ('audit', 'repurpose')",
      name: "processing_runs_candidate_mode_valid"
  end
end
