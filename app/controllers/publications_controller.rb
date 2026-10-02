class PublicationsController < ApplicationController
  before_action :require_authentication
  before_action :set_publication, only: :show

  def new
    @score = owned_score
    @publication = current_user.publications.new(
      candidate_clip: @score.candidate_clip,
      published_at: Time.current,
      platform: params[:platform].presence || "instagram"
    )
    load_accounts
  end

  def create
    @score = owned_score
    prediction = prediction_for(@score)
    @publication = current_user.publications.new(publication_params.merge(
      candidate_clip: @score.candidate_clip,
      ranking_prediction: prediction,
      source: "manual"
    ))
    if @publication.save
      enqueue_collection(@publication)
      redirect_to feedback_dashboard_path, notice: "Published clip recorded. Its outcome will only become a label near 72 hours."
    else
      load_accounts
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @snapshot = @publication.metric_snapshots.new(observed_at: Time.current)
  end

  private

  def owned_score
    CandidateScore.joins(candidate_clip: :video).where(videos: { user_id: current_user.id }).find(params[:candidate_score_id])
  end

  def set_publication
    @publication = current_user.publications.includes(:metric_snapshots, :ranking_prediction).find(params[:id])
  end

  def publication_params
    params.require(:publication).permit(:platform, :platform_account_key, :post_id, :post_url, :published_at, :demo_data)
  end

  def prediction_for(score)
    score.ranking_run.ranking_predictions.find_by(candidate_clip: score.candidate_clip) ||
      score.ranking_run.ranking_predictions.create!(
        candidate_clip: score.candidate_clip,
        frozen_features: Feedback::FeatureSnapshot.from(
          score.candidate_clip.candidate_feature_sets.find_by!(feature_version: score.ranking_run.feature_version)
        ),
        schema_version: score.ranking_run.feature_version,
        feature_model_version: score.candidate_clip.candidate_feature_sets.find_by!(feature_version: score.ranking_run.feature_version).model_version,
        baseline_score: score.clip_score,
        baseline_rank: score.rank,
        baseline_model_version: score.ranking_run.scorer_version,
        selected_scorer: score.ranking_run.scorer_version,
        fallback_reason: "legacy_prediction_backfill",
        recommended_at: score.ranking_run.completed_at || score.created_at
      )
  end

  def enqueue_collection(publication)
    collection_time = publication.published_at + 72.hours
    return if Time.current > publication.published_at + MetricSnapshot::MATURE_AGE_RANGE.end.hours

    CollectPublicationMetricsJob.set(wait_until: [ collection_time, Time.current ].max).perform_later(publication.id)
  end

  def load_accounts
    @instagram_accounts = current_user.instagram_accounts.order(:username)
    @linkedin_accounts = current_user.linkedin_accounts.order(:display_name)
  end
end
