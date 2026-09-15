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
    @processing_run = @video.processing_runs.order(created_at: :desc).first
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
end
