module Feedback
  class PredictionRecorder
    def self.call(ranking_run:, baseline_candidates:, feedback_data: nil, model_version: nil, fallback_reason: nil)
      new(ranking_run, baseline_candidates, feedback_data, model_version, fallback_reason).call
    end

    def initialize(ranking_run, baseline_candidates, feedback_data, model_version, fallback_reason)
      @ranking_run = ranking_run
      @baseline_by_id = baseline_candidates.index_by { |item| item.fetch("candidate_id").to_s }
      @feedback_by_id = Array(feedback_data&.fetch("ranked_candidates", nil)).index_by { |item| item.fetch("candidate_id").to_s }
      @model_version = model_version
      @fallback_reason = fallback_reason
    end

    def call
      RankingPrediction.transaction do
        @ranking_run.candidate_scores.includes(candidate_clip: :candidate_feature_sets).find_each do |score|
          candidate = score.candidate_clip
          baseline = @baseline_by_id.fetch(candidate.id.to_s)
          feedback = @feedback_by_id[candidate.id.to_s]
          feature_set = candidate.candidate_feature_sets.find_by!(feature_version: @ranking_run.feature_version)
          selected = @model_version&.active? && feedback.present? ? "feedback-linear-1" : "heuristic-1"

          @ranking_run.ranking_predictions.create!(
            candidate_clip: candidate,
            model_version: feedback.present? ? @model_version : nil,
            frozen_features: FeatureSnapshot.from(feature_set),
            schema_version: feature_set.feature_version,
            feature_model_version: feature_set.model_version,
            baseline_score: baseline.fetch("clip_score"),
            baseline_rank: baseline.fetch("rank"),
            feedback_score: feedback&.fetch("predicted_outcome", nil),
            feedback_display_score: feedback&.fetch("feedback_score", nil),
            feedback_rank: feedback&.fetch("rank", nil),
            model_contributions: feedback&.fetch("contributions", []) || [],
            selected_scorer: selected,
            fallback_reason: selected == "heuristic-1" ? @fallback_reason : nil,
            recommended_at: @ranking_run.completed_at || Time.current
          )
        end
      end
    end
  end
end
