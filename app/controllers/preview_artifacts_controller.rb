class PreviewArtifactsController < ApplicationController
  before_action :require_authentication
  before_action :set_video

  # Keep object storage private and stream only an owned, currently ranked
  # artifact. This also keeps browser delivery independent from an internal
  # S3-compatible hostname (for example, MinIO's Docker network name).
  def show
    artifact = owned_artifact
    return head :not_found unless artifact&.ready? && artifact.file.attached?

    if direct_media_delivery?
      redirect_to artifact.file.url(expires_in: 5.minutes), allow_other_host: true
    else
      deliver(artifact.file.blob)
    end
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

  def direct_media_delivery?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("DIRECT_MEDIA_DELIVERY", "false"))
  end

  def deliver(blob)
    range = requested_range(blob.byte_size)
    payload = range ? blob.download_chunk(range) : blob.download

    response.headers["Accept-Ranges"] = "bytes"
    response.headers["Cache-Control"] = "private, max-age=300"
    response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{blob.byte_size}" if range
    send_data(
      payload,
      type: blob.content_type,
      disposition: "inline",
      filename: blob.filename.to_s,
      status: range ? :partial_content : :ok
    )
  rescue RangeError
    response.headers["Content-Range"] = "bytes */#{blob.byte_size}"
    head :range_not_satisfiable
  end

  def requested_range(size)
    header = request.headers["Range"]
    return if header.blank?

    match = /\Abytes=(\d*)-(\d*)\z/.match(header)
    raise RangeError unless match && (match[1].present? || match[2].present?)

    if match[1].blank?
      length = match[2].to_i
      raise RangeError unless length.positive?

      start_byte = [ size - length, 0 ].max
      return start_byte..(size - 1)
    end

    start_byte = match[1].to_i
    end_byte = match[2].present? ? [ match[2].to_i, size - 1 ].min : size - 1
    raise RangeError if start_byte >= size || end_byte < start_byte

    start_byte..end_byte
  end
end
