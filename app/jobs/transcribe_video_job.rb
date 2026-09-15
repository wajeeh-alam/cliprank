class TranscribeVideoJob < ApplicationJob
  include Pipeline::JobSupport

  queue_as :default
  retry_on Ml::Client::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.send(:record_terminal_error, job.arguments[0], job.arguments[1], error)
  end

  def perform(video_id, processing_run_id, injected_client = nil, client: nil)
    client ||= injected_client
    started = begin_stage!(
      video_id, processing_run_id,
      stage: "extracting_audio", completed_stage: "transcription_complete", video_status: "extracting_audio"
    )
    if started == :skip
      run = ProcessingRun.find(processing_run_id)
      GenerateCandidatesJob.perform_later(video_id, processing_run_id) if run.current_stage == "transcription_complete"
      return
    end

    run, video = load_processing_records(video_id, processing_run_id)
    transcript_version = ENV.fetch("ML_TRANSCRIPT_VERSION", "whisper-1")
    duration_ms = ensure_video_duration!(video)
    transition_to_transcribing!(video_id, processing_run_id)
    payload = {
      "video_id" => video.id.to_s,
      "media" => source_media_payload(video),
      "duration_ms" => duration_ms,
      "transcript_version" => transcript_version,
      "language" => nil
    }
    response = client_for(client).transcribe(
      payload,
      request_id: request_id(video.id, run.id, "transcription"),
      idempotency_key: "video/#{video.id}/run/#{run.id}/transcription"
    )
    data = validate_transcription_data!(response, video_id: video.id, transcript_version: transcript_version)
    persisted = mark_transcription_complete!(video.id, run.id, transcript_version, data.fetch("segments"))
    GenerateCandidatesJob.perform_later(video.id, run.id) if persisted || ProcessingRun.find(run.id).current_stage == "transcription_complete"
  rescue Ml::Client::PermanentError => e
    record_terminal_error(video_id, processing_run_id, e)
    nil
  rescue ActiveRecord::RecordInvalid => e
    error = Ml::Client::PermanentError.new("The transcription result could not be saved", code: "PERSISTENCE_ERROR", details: { "validation_errors" => e.record.errors.to_hash })
    record_terminal_error(video_id, processing_run_id, error)
    nil
  rescue ActiveRecord::RecordNotUnique => e
    error = Ml::Client::PermanentError.new("The transcription result conflicted with an existing result", code: "DUPLICATE_RESULT", details: { "class" => e.class.name })
    record_terminal_error(video_id, processing_run_id, error)
    nil
  rescue Ml::Client::Error => e
    raise if e.retryable

    record_terminal_error(video_id, processing_run_id, e)
    nil
  end
end
