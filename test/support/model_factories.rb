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
        semantic_features: semantic_features,
        audio_features: { "words_per_minute" => 165.0 },
        visual_features: { "face_presence_ratio" => 0.8 },
        structural_features: { "sentence_completeness" => 0.9 }
      }.merge(attributes)
    )
  end

  def create_ranking_run(video: create_video, **attributes)
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
