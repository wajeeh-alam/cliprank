class RenderPreviewsJob < ApplicationJob
  include Pipeline::JobSupport

  queue_as :default
  retry_on Previews::Renderer::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    video_id, processing_run_id, ranking_run_id = job.arguments
    job.send(:record_preview_terminal_error, video_id, processing_run_id, ranking_run_id, error)
  end

  def perform(video_id, processing_run_id, ranking_run_id = nil)
    run, video = load_processing_records(video_id, processing_run_id)
    ranking_run = if ranking_run_id
      run.ranking_runs.find(ranking_run_id)
    else
      run.ranking_runs.where(status: "succeeded").order(id: :desc).first
    end
    raise ActiveRecord::RecordNotFound, "successful ranking run is required" unless ranking_run
    raise ActiveRecord::RecordNotFound, "ranking run does not belong to video" unless ranking_run.video_id == video.id
    return unless begin_preview_stage!(run, video)

    Previews::Renderer.call(ranking_run)
  rescue Previews::Renderer::PermanentError => error
    record_preview_terminal_error(video_id, processing_run_id, ranking_run_id, error)
    nil
  end

  private

  def begin_preview_stage!(run, video)
    ProcessingRun.transaction do
      run.lock!
      video.lock!
      return false if run.failed? || run.succeeded?
      unless %w[ranking_complete generating_previews].include?(run.current_stage)
        raise Previews::Renderer::PermanentError.new(
          "Preview rendering requires a completed ranking",
          code: "PREVIEW_STAGE_INVALID"
        )
      end

      run.update!(
        status: "running",
        current_stage: "generating_previews",
        attempt_count: run.attempt_count + 1,
        error_code: nil,
        error_message: nil,
        error_details: {}
      )
      video.update!(
        status: "generating_previews",
        processing_error_code: nil,
        processing_error_message: nil,
        processing_error_details: {}
      )
      true
    end
  end

  def record_preview_terminal_error(video_id, processing_run_id, ranking_run_id, error)
    message = safe_message(error.message)
    ProcessingRun.transaction do
      run = ProcessingRun.lock.find(processing_run_id)
      next unless run.video_id.to_i == video_id.to_i
      next if run.failed? || run.succeeded?

      video = Video.lock.find(run.video_id)
      ranking_run_id ||= run.ranking_runs.where(status: "succeeded").order(id: :desc).pick(:id)
      details = run.error_details.is_a?(Hash) ? run.error_details.deep_dup : {}
      details["preview_error"] = { "code" => error.code.to_s, "message" => message }
      PreviewArtifact.where(ranking_run_id: ranking_run_id).where.not(status: "ready").update_all(
        status: "failed",
        error_code: error.code.to_s,
        error_message: message,
        updated_at: Time.current
      )
      run.update!(status: "failed", current_stage: "generating_previews", error_code: error.code, error_message: message, error_details: details, completed_at: Time.current)
      video.update!(status: "failed", processing_error_code: error.code, processing_error_message: message, processing_error_details: details)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def safe_message(value)
    message = value.to_s.gsub(%r{/(?:[^\s/]+/)+[^\s]*}, "[redacted-path]")
    message = "Preview rendering failed." if message.empty?
    message[0, 500]
  end
end
