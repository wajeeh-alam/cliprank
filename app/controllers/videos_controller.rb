class VideosController < ApplicationController
  before_action :require_authentication
  before_action :set_video, only: :show

  ALLOWED_MEDIA_TYPES = %w[video/mp4 video/quicktime].freeze
  PIPELINE_VERSION = "phase1".freeze

  def index
    @videos = current_user.videos.order(created_at: :desc)
  end

  def new
    @video = current_user.videos.new(pipeline_version: PIPELINE_VERSION)
  end

  def create
    @video = current_user.videos.new(
      title: video_params[:title], pipeline_version: PIPELINE_VERSION, status: "uploading"
    )
    source_media = params.dig(:video, :source_media)

    validate_source_media(source_media)
    return render(:new, status: :unprocessable_entity) if @video.errors.any?

    ActiveRecord::Base.transaction do
      @video.save!
      @video.source_media.attach(source_media)
      @processing_run = @video.processing_runs.create!(
        pipeline_version: @video.pipeline_version,
        idempotency_key: SecureRandom.uuid,
        status: "pending"
      )
    end

    # This call intentionally occurs after the transaction block has committed.
    TranscribeVideoJob.perform_later(@video.id, @processing_run.id)
    redirect_to video_path(@video), notice: "Upload received. Processing will begin shortly."
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  def show
    @processing_run = @video.processing_runs.order(created_at: :desc, id: :desc).first
    @ranking_run = @video.ranking_runs
      .joins(:processing_run)
      .where(status: "succeeded")
      .where.not(completed_at: nil)
      .where(processing_runs: { video_id: @video.id })
      .order(ranking_runs: { completed_at: :desc, id: :desc })
      .first
    @results_fallback = @ranking_run.present? && @processing_run.present? && @ranking_run.processing_run_id != @processing_run.id
    @ranked_scores = []
    @preview_artifacts_by_candidate = {}
    @title_ideas_pending = false
    return unless @ranking_run

    all_scores = @ranking_run.candidate_scores
    owned_scores = all_scores.joins(:candidate_clip).where(candidate_clips: { video_id: @video.id })
    explained_count = Explanation.joins(:candidate_score).where(
      candidate_scores: { ranking_run_id: @ranking_run.id },
      explanation_version: Explanations::Generator::VERSION
    ).count
    @results_pending = all_scores.count.zero? || owned_scores.count != all_scores.count || explained_count != all_scores.count
    @preview_pending = @ranking_run.present? && !@video.complete? && !@video.failed?
    current_title_version = @ranking_run.title_ideas_version == TitleIdeas::Generator::VERSION
    @title_ideas_pending = !current_title_version || %w[pending generating].include?(@ranking_run.title_ideas_status)
    if !current_title_version || @ranking_run.title_ideas_status == "pending"
      begin
        TitleIdeas::Enqueuer.call(@ranking_run)
      rescue StandardError => e
        Rails.logger.warn("Title idea backfill could not be queued for ranking run #{@ranking_run.id}: #{e.class}")
      end
    end
    return if @results_pending

    @ranked_scores = owned_scores
      .includes(:explanations, candidate_clip: :candidate_feature_sets)
      .order(:rank, :id)
      .limit(5)
    @title_idea_sets_by_candidate = TitleIdeaSet
      .where(ranking_run_id: @ranking_run.id, candidate_clip_id: @ranked_scores.map(&:candidate_clip_id), version: TitleIdeas::Generator::VERSION)
      .includes(:title_ideas)
      .index_by(&:candidate_clip_id)
    load_preview_artifacts
  end

  private

  def set_video
    @video = current_user.videos.find(params[:id])
  end

  def video_params
    params.require(:video).permit(:title)
  end

  def validate_source_media(source_media)
    if source_media.blank?
      @video.errors.add(:source_media, "must be selected")
      return
    end

    return if ALLOWED_MEDIA_TYPES.include?(source_media.content_type.to_s)

    @video.errors.add(:source_media, "must be an MP4 or MOV video")
  end

  def load_preview_artifacts
    @preview_artifacts_by_candidate = PreviewArtifact
      .joins(:ranking_run, :candidate_clip)
      .where(
        ranking_run_id: @ranking_run.id,
        candidate_clip_id: @ranked_scores.map(&:candidate_clip_id),
        render_version: Previews::Renderer::VERSION
      )
      .where(ranking_runs: { video_id: @video.id }, candidate_clips: { video_id: @video.id })
      .order(id: :desc)
      .to_a
      .each_with_object({}) do |artifact, grouped|
        grouped[artifact.candidate_clip_id] ||= {}
        grouped[artifact.candidate_clip_id][artifact.kind.to_s] ||= artifact
      end
  end
end
