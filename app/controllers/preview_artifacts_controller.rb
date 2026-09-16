class PreviewArtifactsController < ApplicationController
  before_action :require_authentication
  before_action :set_video

  # The page only exposes this endpoint. The endpoint then redirects to the
  # storage service's short-lived URL, keeping blob keys and permanent blob
  # routes out of the rendered document.
  def show
    artifact = owned_artifact
    return head :not_found unless artifact&.ready? && artifact.file.attached?

    redirect_to artifact.file.url(expires_in: 5.minutes), allow_other_host: true
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
    head :not_found
  end

  private

  def set_video
    @video = current_user.videos.find(params[:video_id])
  end

  def owned_artifact
    artifact = PreviewArtifact
      .joins(:ranking_run, :candidate_clip)
      .where(id: params[:id])
      .where(ranking_run_id: displayed_ranking_run&.id)
      .where(render_version: Previews::Renderer::VERSION)
      .where(ranking_runs: { video_id: @video.id })
      .where(candidate_clips: { video_id: @video.id })
      .first
    return unless artifact
    return unless artifact.ranking_run.candidate_scores.where(candidate_clip_id: artifact.candidate_clip_id, rank: 1..5).exists?

    artifact
  end

  def displayed_ranking_run
    @displayed_ranking_run ||= @video.ranking_runs
      .joins(:processing_run)
      .where(status: "succeeded")
      .where.not(completed_at: nil)
      .where(processing_runs: { video_id: @video.id })
      .order(ranking_runs: { completed_at: :desc, id: :desc })
      .first
  end
end
