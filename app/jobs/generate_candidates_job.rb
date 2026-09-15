class GenerateCandidatesJob < ApplicationJob
  include Pipeline::JobSupport

  queue_as :default
  retry_on Ml::Client::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.send(:record_terminal_error, job.arguments[0], job.arguments[1], error)
  end

  def perform(video_id, processing_run_id, injected_client = nil, client: nil)
    client ||= injected_client
    started = begin_stage!(
      video_id, processing_run_id,
      stage: "generating_candidates", completed_stage: "candidates_complete", video_status: "generating_candidates"
    )
    if started == :skip
      run = ProcessingRun.find(processing_run_id)
      generation_version = ENV.fetch("ML_GENERATION_VERSION", "candidate-1")
      if %w[candidates_complete extracting_features].include?(run.current_stage)
        enqueue_feature_jobs!(video_id, processing_run_id, generation_version)
      end
      return
    end

    run, video = load_processing_records(video_id, processing_run_id)
    transcript_version = ENV.fetch("ML_TRANSCRIPT_VERSION", "whisper-1")
    generation_version = ENV.fetch("ML_GENERATION_VERSION", "candidate-1")
    if video.duration_ms.nil?
      raise Ml::Client::PermanentError.new("The source duration is required for candidate generation", code: "SOURCE_DURATION_MISSING")
    end
    segments = video.transcript_segments.where(transcript_version: transcript_version).order(:sequence).to_a
    if segments.empty?
      raise Ml::Client::PermanentError.new("A transcript is required before candidates can be generated", code: "TRANSCRIPT_MISSING")
    end

    payload = {
      "video_id" => video.id.to_s,
      "duration_ms" => video.duration_ms,
      "generation_version" => generation_version,
      "min_duration_ms" => 15_000,
      "max_duration_ms" => 60_000,
      "target_count_min" => 10,
      "target_count_max" => 40,
      "segments" => segments.map do |segment|
        {
          "sequence" => segment.sequence,
          "start_ms" => segment.start_ms,
          "end_ms" => segment.end_ms,
          "text" => segment.text,
          "is_sentence_boundary_start" => segment.is_sentence_boundary_start,
          "is_sentence_boundary_end" => segment.is_sentence_boundary_end
        }
      end
    }
    response = client_for(client).generate_candidates(
      payload,
      request_id: request_id(video.id, run.id, "candidates"),
      idempotency_key: "video/#{video.id}/run/#{run.id}/candidates"
    )
    data = validate_candidate_data!(response, video_id: video.id, generation_version: generation_version, duration_ms: video.duration_ms)
    if data.fetch("candidates").empty?
      raise Ml::Client::PermanentError.new("The source did not produce any valid candidates", code: "NO_CANDIDATES")
    end
    persisted = mark_candidates_complete!(video.id, run.id, generation_version, data.fetch("candidates"))
    enqueue_feature_jobs!(video.id, run.id, generation_version) if persisted || ProcessingRun.find(run.id).current_stage == "candidates_complete"
  rescue Ml::Client::PermanentError => e
    record_terminal_error(video_id, processing_run_id, e)
    nil
  rescue ActiveRecord::RecordInvalid => e
    error = Ml::Client::PermanentError.new("The candidate result could not be saved", code: "PERSISTENCE_ERROR", details: { "validation_errors" => e.record.errors.to_hash })
    record_terminal_error(video_id, processing_run_id, error)
    nil
  rescue ActiveRecord::RecordNotUnique => e
    error = Ml::Client::PermanentError.new("The candidate result conflicted with an existing result", code: "DUPLICATE_RESULT", details: { "class" => e.class.name })
    record_terminal_error(video_id, processing_run_id, error)
    nil
  rescue Ml::Client::Error => e
    raise if e.retryable

    record_terminal_error(video_id, processing_run_id, e)
    nil
  end
end
