class RankCandidatesJob < ApplicationJob
  include Pipeline::JobSupport

  queue_as :default
  retry_on Ml::Client::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.send(:record_ranking_terminal_error, job.arguments[0], job.arguments[1], error)
  end

  def perform(video_id, processing_run_id, injected_client = nil, client: nil)
    client ||= injected_client
    config = Pipeline::RankingConfig.for
    started, ranking_run_id = begin_ranking!(video_id, processing_run_id, config)
    if started == :skip
      run, = load_processing_records(video_id, processing_run_id)
      ranking_run_id ||= run.ranking_runs.where(status: "succeeded").order(id: :desc).pick(:id)
      if ranking_run_id
        begin
          Explanations::Generator.call(run.ranking_runs.find(ranking_run_id))
        rescue Explanations::Generator::Error => e
          Rails.logger.warn("Explanation backfill skipped for ranking run #{ranking_run_id}: #{e.message}")
        end
        enqueue_preview_job!(video_id, processing_run_id, ranking_run_id) if run.reload.current_stage == "ranking_complete"
      end
      return
    end

    run, video = load_processing_records(video_id, processing_run_id)
    ranking_run = RankingRun.find(ranking_run_id)
    feature_version = ranking_run.feature_version
    scorer_version = ranking_run.scorer_version
    request_config = normalize_payload(ranking_run.config)
    candidates = video.candidate_clips.order(:sequence, :id).each_with_object([]) do |candidate, ranked_input|
      feature_set = candidate.candidate_feature_sets.find_by(feature_version: feature_version)
      next if feature_set.nil? || candidate.status == "failed"

      ranked_input << {
        "candidate_id" => candidate.id.to_s,
        "start_ms" => candidate.start_ms,
        "end_ms" => candidate.end_ms,
        "features" => {
          "video_id" => video.id.to_s,
          "candidate_id" => candidate.id.to_s,
          "feature_version" => feature_set.feature_version,
          "model_version" => feature_set.model_version,
          "prompt_version" => feature_set.prompt_version,
          "semantic" => feature_set.semantic_features,
          "audio" => feature_set.audio_features,
          "visual" => feature_set.visual_features,
          "structural" => feature_set.structural_features,
          "capability_warnings" => Array(feature_set.raw_metadata["capability_warnings"])
        }
      }
    end
    minimum = [ ENV.fetch("ML_MIN_VALID_CANDIDATES", "5").to_i, 1 ].max
    if candidates.length < minimum
      raise Ml::Client::PermanentError.new(
        "Not enough candidates have valid feature sets for ranking",
        code: "INSUFFICIENT_VALID_CANDIDATES",
        details: { "valid_candidate_count" => candidates.length, "required_candidate_count" => minimum }
      )
    end

    payload = {
      "video_id" => video.id.to_s,
      "feature_version" => feature_version,
      "scorer_version" => scorer_version,
      "config" => request_config.fetch("request_config", request_config),
      "candidates" => candidates
    }
    response = client_for(client).rank(
      payload,
      request_id: request_id(video.id, run.id, "rank"),
      idempotency_key: "video/#{video.id}/run/#{run.id}/rank"
    )
    data = validate_rank_data!(
      response,
      video_id: video.id,
      feature_version: feature_version,
      scorer_version: scorer_version,
      candidate_ids: candidates.map { |candidate| candidate.fetch("candidate_id") },
      expected_weights: request_config.fetch("weights")
    )
    result = mark_ranking_complete!(video.id, run.id, ranking_run.id, data.fetch("ranked_candidates"))
    enqueue_preview_job!(video.id, run.id, ranking_run.id) if result == :succeeded
  rescue Ml::Client::PermanentError => e
    record_ranking_terminal_error(video_id, processing_run_id, e)
    nil
  rescue ActiveRecord::RecordInvalid => e
    error = Ml::Client::PermanentError.new(
      "The ranking result could not be saved",
      code: "PERSISTENCE_ERROR",
      details: { "validation_errors" => e.record.errors.to_hash }
    )
    record_ranking_terminal_error(video_id, processing_run_id, error)
    nil
  rescue ActiveRecord::RecordNotUnique => e
    error = Ml::Client::PermanentError.new(
      "The ranking result conflicted with an existing result",
      code: "DUPLICATE_RESULT",
      details: { "class" => e.class.name }
    )
    record_ranking_terminal_error(video_id, processing_run_id, error)
    nil
  rescue Explanations::Generator::Error => e
    error = Ml::Client::PermanentError.new(
      "The deterministic explanation could not be generated",
      code: "EXPLANATION_ERROR",
      details: { "message" => e.message }
    )
    record_ranking_terminal_error(video_id, processing_run_id, error)
    nil
  rescue Ml::Client::Error => e
    raise if e.retryable

    record_ranking_terminal_error(video_id, processing_run_id, e)
    nil
  end
end
