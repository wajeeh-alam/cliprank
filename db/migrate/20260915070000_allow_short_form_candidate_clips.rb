class AllowShortFormCandidateClips < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :candidate_clips, name: "candidate_clips_duration_range"
    add_check_constraint :candidate_clips,
      "duration_ms = end_ms - start_ms AND duration_ms BETWEEN 3000 AND 60000",
      name: "candidate_clips_duration_range"
  end

  def down
    remove_check_constraint :candidate_clips, name: "candidate_clips_duration_range"
    add_check_constraint :candidate_clips,
      "duration_ms = end_ms - start_ms AND duration_ms BETWEEN 15000 AND 60000",
      name: "candidate_clips_duration_range"
  end
end
