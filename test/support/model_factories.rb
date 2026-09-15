module ModelFactories
  def build_user
    User.new(
      email: "creator-#{SecureRandom.hex(4)}@example.com", name: "Creator",
      password: "password-123", password_confirmation: "password-123"
    )
  end

  def create_video(**attributes)
    user = build_user
    user.save!
    user.videos.create!(
      { title: "Long recording", pipeline_version: "phase1-test" }.merge(attributes)
    )
  end

  def create_candidate(video: create_video, **attributes)
    video.candidate_clips.create!(
      {
        sequence: 1,
        start_ms: 0,
        end_ms: 20_000,
        duration_ms: 20_000,
        transcript: "A complete idea.",
        generation_version: "candidate-test"
      }.merge(attributes)
    )
  end

  def semantic_features
    CandidateFeatureSet::NORMALIZED_SEMANTIC_FEATURES.index_with { 0.75 }.merge(
      "topic" => "coding",
      "content_type" => "tutorial",
      "hook_type" => "question"
    )
  end

  def create_feature_set(candidate: create_candidate, **attributes)
    candidate.candidate_feature_sets.create!(
      {
        feature_version: "features-test",
        model_version: "semantic-test",
        semantic_features: semantic_features,
        audio_features: {
          "words_per_minute" => 165.0,
          "average_audio_energy" => 0.62,
          "energy_variance" => 0.18,
          "energy_change_at_hook" => 0.21,
          "silence_ratio" => 0.03,
          "longest_pause_ms" => 820,
          "pause_frequency" => 0.07
        },
        visual_features: {
          "face_presence_ratio" => 0.8,
          "visual_motion" => 0.31,
          "scene_change_rate" => 0.04,
          "screen_recording_ratio" => 0.0,
          "camera_change_frequency" => 0.02,
          "sample_count" => 20
        },
        structural_features: {
          "time_to_main_point_ms" => 1400,
          "intro_length_ms" => 1200,
          "sentence_completeness" => 0.9,
          "hook_to_payoff_time_ms" => 22_400,
          "dead_air_start_ms" => 0,
          "dead_air_end_ms" => 2100
        }
      }.merge(attributes)
    )
  end

  def create_ranking_run(video: create_video, **attributes)
    attributes[:processing_run] ||= video.processing_runs.create!(
      pipeline_version: video.pipeline_version,
      idempotency_key: "ranking/#{SecureRandom.uuid}"
    )
    video.ranking_runs.create!(
      {
        feature_version: "features-test",
        scorer_version: "scorer-test",
        config: { "weights" => { "hook" => 0.2 } }
      }.merge(attributes)
    )
  end

  def create_score(ranking_run: create_ranking_run, candidate_clip: create_candidate(video: ranking_run.video), **attributes)
    ranking_run.candidate_scores.create!(
      {
        candidate_clip: candidate_clip,
        rank: 1,
        clip_score: 91.25,
        content_quality: 94,
        hook: 88,
        delivery: 83,
        pacing: 91,
        visual_engagement: 78,
        standalone_clarity: 96,
        component_details: { "hook" => { "contribution" => 17.6 } }
      }.merge(attributes)
    )
  end
end
