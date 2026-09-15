class ExtractCandidateFeaturesJob < ApplicationJob
  include Pipeline::JobSupport

  queue_as :default
  retry_on Ml::Client::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.send(:record_candidate_terminal_error, job.arguments[0], job.arguments[1], job.arguments[2], error)
  end

  # Feature extraction is intentionally fan-out: one job owns one candidate
  # lock and one stable idempotency key. A slow or malformed candidate cannot
  # duplicate or roll back feature rows for its siblings.
  def perform(video_id, processing_run_id, candidate_id, injected_client = nil, client: nil)
    client ||= injected_client
    feature_version = ENV.fetch("ML_FEATURE_VERSION", "features-1")
    started = begin_candidate_feature!(video_id, processing_run_id, candidate_id, feature_version)
    if started == :skip
      run = ProcessingRun.find(processing_run_id)
      enqueue_rank_job!(video_id, processing_run_id) if run.current_stage == "features_complete"
      return
    end

    run, video = load_processing_records(video_id, processing_run_id)
    candidate = CandidateClip.find(candidate_id)
    raise ActiveRecord::RecordNotFound, "candidate clip does not belong to video" unless candidate.video_id == video.id

    transcript_version = ENV.fetch("ML_TRANSCRIPT_VERSION", "whisper-1")
    transcript_segments = video.transcript_segments
      .where(transcript_version: transcript_version)
      .where("start_ms >= ? AND end_ms <= ?", candidate.start_ms, candidate.end_ms)
      .order(:sequence)
      .to_a
    if transcript_segments.empty?
      raise Ml::Client::PermanentError.new("Transcript segments are required for feature extraction", code: "TRANSCRIPT_SEGMENTS_MISSING")
    end

    payload = {
      "video_id" => video.id.to_s,
      "candidate_id" => candidate.id.to_s,
      "feature_version" => feature_version,
      "media" => source_media_payload(video),
      "start_ms" => candidate.start_ms,
      "end_ms" => candidate.end_ms,
      "transcript" => candidate.transcript,
      "transcript_segments" => transcript_segments.map do |segment|
        {
          "sequence" => segment.sequence,
          "start_ms" => segment.start_ms,
          "end_ms" => segment.end_ms,
          "text" => segment.text,
          "words" => segment.words,
          "is_sentence_boundary_start" => segment.is_sentence_boundary_start,
          "is_sentence_boundary_end" => segment.is_sentence_boundary_end
        }
      end
    }
    response = client_for(client).extract_features(
      payload,
      request_id: request_id(video.id, run.id, "features-candidate-#{candidate.id}"),
      idempotency_key: "video/#{video.id}/run/#{run.id}/features/candidate/#{candidate.id}"
    )
    data = validate_feature_data!(
      response,
      video_id: video.id,
      candidate_id: candidate.id,
      feature_version: feature_version
    )
    barrier_state = mark_feature_complete!(video.id, run.id, candidate.id, data)
    enqueue_rank_job!(video.id, run.id) if barrier_state == :features_complete
  rescue Ml::Client::PermanentError => e
    barrier_state = record_candidate_terminal_error(video_id, processing_run_id, candidate_id, e)
    enqueue_rank_job!(video_id, processing_run_id) if barrier_state == :features_complete
    nil
  rescue ActiveRecord::RecordInvalid => e
    error = Ml::Client::PermanentError.new(
      "The candidate feature result could not be saved",
      code: "PERSISTENCE_ERROR",
      details: { "validation_errors" => e.record.errors.to_hash }
    )
    barrier_state = record_candidate_terminal_error(video_id, processing_run_id, candidate_id, error)
    enqueue_rank_job!(video_id, processing_run_id) if barrier_state == :features_complete
    nil
  rescue ActiveRecord::RecordNotUnique => e
    error = Ml::Client::PermanentError.new(
      "The candidate feature result conflicted with an existing result",
      code: "DUPLICATE_RESULT",
      details: { "class" => e.class.name }
    )
    barrier_state = record_candidate_terminal_error(video_id, processing_run_id, candidate_id, error)
    enqueue_rank_job!(video_id, processing_run_id) if barrier_state == :features_complete
    nil
  rescue Ml::Client::Error => e
    raise if e.retryable

    barrier_state = record_candidate_terminal_error(video_id, processing_run_id, candidate_id, e)
    enqueue_rank_job!(video_id, processing_run_id) if barrier_state == :features_complete
    nil
  end
end
