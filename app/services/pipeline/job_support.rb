require "securerandom"

module Pipeline
  module JobSupport
    STAGE_ORDER = {
      "extracting_audio" => 10,
      "transcribing" => 20,
      "transcription_complete" => 30,
      "generating_candidates" => 40,
      "candidates_complete" => 50,
      "extracting_features" => 60,
      "features_complete" => 65,
      "ranking" => 70,
      "ranking_complete" => 80,
      "generating_previews" => 90,
      "complete" => 100
    }.freeze

    private

    def load_processing_records(video_id, processing_run_id)
      run = ProcessingRun.find(processing_run_id)
      raise ActiveRecord::RecordNotFound, "processing run does not belong to video" unless run.video_id.to_i == video_id.to_i

      [ run, run.video ]
    end

    def stage_complete?(run, stage)
      STAGE_ORDER.fetch(run.current_stage.to_s, -1) >= STAGE_ORDER.fetch(stage.to_s)
    end

    def begin_stage!(video_id, processing_run_id, stage:, completed_stage:, video_status:)
      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        raise ActiveRecord::RecordNotFound, "processing run does not belong to video" unless run.video_id.to_i == video_id.to_i

        video = Video.lock.find(run.video_id)
        return :skip if run.failed? || run.succeeded? || stage_complete?(run, completed_stage)

        current_order = STAGE_ORDER.fetch(run.current_stage.to_s, -1)
        effective_stage = current_order > STAGE_ORDER.fetch(stage) ? run.current_stage : stage
        effective_video_status = current_order > STAGE_ORDER.fetch(stage) ? video.status : video_status
        run.update!(
          status: "running",
          current_stage: effective_stage,
          started_at: run.started_at || Time.current,
          attempt_count: run.attempt_count + 1,
          error_code: nil,
          error_message: nil,
          error_details: {}
        )
        video.update!(status: effective_video_status, processing_error_code: nil, processing_error_message: nil, processing_error_details: {})
        :started
      end
    end

    def ensure_video_duration!(video)
      return video.duration_ms if video.duration_ms.to_i.positive?

      raise Ml::Client::PermanentError.new("The source media is missing", code: "SOURCE_MEDIA_MISSING") unless video.source_media.attached?

      blob = video.source_media.blob
      blob.analyze unless blob.analyzed?
      duration_ms = (Float(blob.metadata["duration"]) * 1000).round
      unless duration_ms.positive?
        raise Ml::Client::PermanentError.new("The source duration could not be determined", code: "SOURCE_DURATION_MISSING")
      end

      video.update!(duration_ms: duration_ms)
      duration_ms
    rescue ArgumentError, TypeError
      raise Ml::Client::PermanentError.new("The source duration could not be determined", code: "SOURCE_DURATION_MISSING")
    end

    def transition_to_transcribing!(video_id, processing_run_id)
      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        return if run.failed? || run.succeeded? || stage_complete?(run, "transcription_complete")

        video = Video.lock.find(run.video_id)
        video.update!(status: "transcribing") unless video.failed? || video.complete?
        run.update!(current_stage: "transcribing") unless stage_complete?(run, "transcription_complete")
      end
    end

    def mark_transcription_complete!(video_id, processing_run_id, transcript_version, segments)
      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        return false if run.failed? || run.succeeded? || stage_complete?(run, "transcription_complete")

        video = Video.lock.find(run.video_id)
        TranscriptSegment.where(video_id: video.id, transcript_version: transcript_version).delete_all
        segments.each do |segment|
          video.transcript_segments.create!(
            sequence: segment.fetch("sequence"),
            start_ms: segment.fetch("start_ms"),
            end_ms: segment.fetch("end_ms"),
            text: segment.fetch("text"),
            words: segment.fetch("words"),
            is_sentence_boundary_start: segment.fetch("is_sentence_boundary_start"),
            is_sentence_boundary_end: segment.fetch("is_sentence_boundary_end"),
            transcript_version: transcript_version
          )
        end
        run.update!(status: "running", current_stage: "transcription_complete", error_code: nil, error_message: nil, error_details: {})
        video.update!(status: "generating_candidates", processing_error_code: nil, processing_error_message: nil, processing_error_details: {})
        true
      end
    end

    def mark_candidates_complete!(video_id, processing_run_id, generation_version, candidates)
      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        return false if run.failed? || run.succeeded? || stage_complete?(run, "candidates_complete")

        video = Video.lock.find(run.video_id)
        CandidateClip.where(video_id: video.id, generation_version: generation_version).delete_all
        candidates.each do |candidate|
          video.candidate_clips.create!(
            sequence: candidate.fetch("sequence"),
            start_ms: candidate.fetch("start_ms"),
            end_ms: candidate.fetch("end_ms"),
            duration_ms: candidate.fetch("duration_ms"),
            transcript: candidate.fetch("transcript"),
            status: "pending",
            generation_version: generation_version
          )
        end
        run.update!(status: "running", current_stage: "candidates_complete", error_code: nil, error_message: nil, error_details: {})
        video.update!(status: "extracting_features", processing_error_code: nil, processing_error_message: nil, processing_error_details: {})
        true
      end
    end

    def enqueue_feature_jobs!(video_id, processing_run_id, generation_version)
      CandidateClip.where(video_id: video_id, generation_version: generation_version).order(:sequence, :id).pluck(:id).each do |candidate_id|
        ExtractCandidateFeaturesJob.perform_later(video_id, processing_run_id, candidate_id)
      end
    end

    def enqueue_rank_job!(video_id, processing_run_id)
      RankCandidatesJob.perform_later(video_id, processing_run_id)
    end

    # Called only after the ranking transaction has returned successfully.  The
    # job itself remains idempotent, so duplicate delivery is safe.
    def enqueue_preview_job!(video_id, processing_run_id, ranking_run_id)
      RenderPreviewsJob.perform_later(video_id, processing_run_id, ranking_run_id)
    end

    def enqueue_title_ideas_job!(ranking_run_id)
      TitleIdeas::Enqueuer.call(RankingRun.find(ranking_run_id))
    end

    def begin_ranking!(video_id, processing_run_id, config)
      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        raise ActiveRecord::RecordNotFound, "processing run does not belong to video" unless run.video_id.to_i == video_id.to_i

        video = Video.lock.find(run.video_id)
        return [ :skip, nil ] if run.failed? || run.succeeded?
        return [ :skip, nil ] if stage_complete?(run, "ranking_complete")
        return [ :skip, nil ] unless stage_complete?(run, "features_complete")

        feature_version = config.fetch("feature_version")
        scorer_version = config.fetch("scorer_version")
        ranking_run = run.ranking_runs.lock.find_by(feature_version: feature_version, scorer_version: scorer_version)
        if ranking_run&.succeeded?
          run.update!(status: "running", current_stage: "ranking_complete")
          video.update!(status: "generating_previews") unless video.failed? || video.complete?
          return [ :skip, ranking_run.id ]
        end

        if ranking_run.nil?
          ranking_run = video.ranking_runs.create!(
            processing_run: run,
            feature_version: feature_version,
            scorer_version: scorer_version,
            config: config.fetch("request_config").deep_dup,
            status: "running",
            started_at: Time.current
          )
        else
          ranking_run.update!(status: "running", started_at: ranking_run.started_at || Time.current, error_code: nil, error_message: nil)
        end
        run.update!(
          status: "running",
          current_stage: "ranking",
          started_at: run.started_at || Time.current,
          attempt_count: run.attempt_count + 1,
          error_code: nil,
          error_message: nil
        )
        video.update!(status: "ranking", processing_error_code: nil, processing_error_message: nil, processing_error_details: {})
        [ :started, ranking_run.id ]
      end
    end

    def mark_ranking_complete!(video_id, processing_run_id, ranking_run_id, ranked_candidates)
      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        return :already_terminal if run.failed? || run.succeeded? || stage_complete?(run, "ranking_complete")

        video = Video.lock.find(run.video_id)
        ranking_run = RankingRun.lock.find(ranking_run_id)
        return :already_succeeded if ranking_run.succeeded?
        raise ActiveRecord::RecordNotFound, "ranking run does not belong to video" unless ranking_run.video_id == video.id

        candidate_ids = ranked_candidates.map { |candidate| candidate.fetch("candidate_id").to_i }
        candidates = video.candidate_clips.where(id: candidate_ids).index_by(&:id)
        raise Ml::Client::ContractError.new("Ranked candidate does not belong to video", code: "RESPONSE_MISMATCH") unless candidates.size == candidate_ids.uniq.size

        ranked_candidates.each do |ranked|
          candidate = candidates.fetch(ranked.fetch("candidate_id").to_i)
          components = ranked.fetch("components")
          candidate.candidate_scores.create!(
            ranking_run: ranking_run,
            rank: ranked.fetch("rank"),
            clip_score: ranked.fetch("clip_score"),
            content_quality: components.fetch("content_quality"),
            hook: components.fetch("hook"),
            delivery: components.fetch("delivery"),
            pacing: components.fetch("pacing"),
            visual_engagement: components.fetch("visual_engagement"),
            standalone_clarity: components.fetch("standalone_clarity"),
            component_details: ranked.fetch("component_details")
          )
          candidate.update!(status: "ranked")
        end
        # Explanations are deterministic templates over the rows just written.
        # Keep them in this transaction so a visible ranking is always fully
        # explainable and a retry cannot expose a partial result set.
        Explanations::Generator.call(ranking_run)
        ranking_run.update!(status: "succeeded", completed_at: Time.current, error_code: nil, error_message: nil)
        run.update!(status: "running", current_stage: "ranking_complete", error_code: nil, error_message: nil)
        video.update!(status: "generating_previews", processing_error_code: nil, processing_error_message: nil, processing_error_details: {})
        :succeeded
      end
    end

    def record_ranking_terminal_error(video_id, processing_run_id, error)
      code = error.respond_to?(:code) && error.code.to_s != "" ? error.code.to_s : "ML_ERROR"
      message = safe_error_message(error)
      details = sanitize_error_details(error.respond_to?(:details) ? error.details : {})
      details["provider_request_id"] = error.request_id.to_s if error.respond_to?(:request_id) && error.request_id
      details["http_status"] = error.status if error.respond_to?(:status) && error.status

      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        next unless run.video_id.to_i == video_id.to_i

        video = Video.lock.find(run.video_id)
        ranking_run = run.ranking_runs.lock.where(status: %w[pending running]).order(id: :desc).first
        ranking_run&.update!(status: "failed", error_code: code, error_message: message, completed_at: Time.current)
        run.update!(status: "failed", error_code: code, error_message: message, error_details: details, completed_at: Time.current)
        video.update!(status: "failed", processing_error_code: code, processing_error_message: message, processing_error_details: details)
      end
      nil
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def begin_candidate_feature!(video_id, processing_run_id, candidate_id, feature_version)
      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        raise ActiveRecord::RecordNotFound, "processing run does not belong to video" unless run.video_id.to_i == video_id.to_i

        video = Video.lock.find(run.video_id)
        candidate = CandidateClip.lock.find(candidate_id)
        raise ActiveRecord::RecordNotFound, "candidate clip does not belong to video" unless candidate.video_id == video.id
        return :skip if run.failed? || run.succeeded?
        return :skip if candidate.candidate_feature_sets.exists?(feature_version: feature_version)
        return :skip unless %w[pending analyzing].include?(candidate.status)
        return :skip if STAGE_ORDER.fetch(run.current_stage.to_s, -1) > STAGE_ORDER.fetch("extracting_features")

        run.update!(status: "running", current_stage: "extracting_features", started_at: run.started_at || Time.current)
        video.update!(status: "extracting_features") unless video.failed? || video.complete?
        candidate.update!(status: "analyzing", processing_error_code: nil, processing_error_message: nil)
        :started
      end
    end

    def mark_feature_complete!(video_id, processing_run_id, candidate_id, feature_data)
      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        return :already_terminal if run.failed? || run.succeeded?

        video = Video.lock.find(run.video_id)
        candidate = CandidateClip.lock.find(candidate_id)
        return :candidate_mismatch unless candidate.video_id == video.id
        return :already_persisted if candidate.candidate_feature_sets.exists?(feature_version: feature_data.fetch("feature_version"))

        candidate.candidate_feature_sets.create!(
          feature_version: feature_data.fetch("feature_version"),
          model_version: feature_data.fetch("model_version"),
          prompt_version: feature_data["prompt_version"],
          semantic_features: feature_data.fetch("semantic"),
          audio_features: feature_data.fetch("audio"),
          visual_features: feature_data.fetch("visual"),
          structural_features: feature_data.fetch("structural"),
          raw_metadata: { "capability_warnings" => feature_data.fetch("capability_warnings") }
        )
        candidate.update!(status: "analyzing", processing_error_code: nil, processing_error_message: nil)
        run.update!(status: "running", current_stage: "extracting_features")
        video.update!(status: "extracting_features") unless video.failed? || video.complete?
        advance_features_barrier!(run, video, candidate.generation_version, feature_data.fetch("feature_version"))
      end
    end

    def record_candidate_terminal_error(video_id, processing_run_id, candidate_id, error)
      code = error.respond_to?(:code) && error.code.to_s != "" ? error.code.to_s : "ML_ERROR"
      message = safe_error_message(error)
      details = sanitize_error_details(error.respond_to?(:details) ? error.details : {})
      details["provider_request_id"] = error.request_id.to_s if error.respond_to?(:request_id) && error.request_id
      details["http_status"] = error.status if error.respond_to?(:status) && error.status

      barrier_state = ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        next unless run.video_id.to_i == video_id.to_i

        video = Video.lock.find(run.video_id)
        candidate = CandidateClip.lock.find(candidate_id)
        next unless candidate.video_id == video.id

        candidate.update!(status: "failed", processing_error_code: code, processing_error_message: message)
        failure = { "candidate_id" => candidate.id.to_s, "code" => code, "message" => message, "details" => details }
        run_details = run.error_details.is_a?(Hash) ? run.error_details.deep_dup : {}
        failures = Array(run_details["feature_failures"]).select { |entry| entry.is_a?(Hash) && entry["candidate_id"].to_s != candidate.id.to_s }
        run_details["feature_failures"] = (failures + [ failure ]).last(100)
        run.update!(error_details: run_details)

        video_details = video.processing_error_details.is_a?(Hash) ? video.processing_error_details.deep_dup : {}
        video_failures = Array(video_details["feature_failures"]).select { |entry| entry.is_a?(Hash) && entry["candidate_id"].to_s != candidate.id.to_s }
        video_details["feature_failures"] = (video_failures + [ failure ]).last(100)
        video.update!(processing_error_details: video_details)
        advance_features_barrier!(run, video, candidate.generation_version, ENV.fetch("ML_FEATURE_VERSION", "features-1"))
      end
      barrier_state
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def advance_features_barrier!(run, video, generation_version, feature_version)
      return if run.failed? || run.succeeded?

      candidates = CandidateClip.where(video_id: video.id, generation_version: generation_version).to_a
      return if candidates.empty?
      return unless candidates.all? do |candidate|
        candidate.status == "failed" || candidate.candidate_feature_sets.exists?(feature_version: feature_version)
      end

      valid_count = candidates.count { |candidate| candidate.candidate_feature_sets.exists?(feature_version: feature_version) }
      minimum = minimum_valid_candidates(video, processing_run: run, available_count: candidates.length)
      if valid_count < minimum
        details = run.error_details.is_a?(Hash) ? run.error_details.deep_dup : {}
        details["valid_candidate_count"] = valid_count
        details["required_candidate_count"] = minimum
        run.update!(
          status: "failed",
          current_stage: "extracting_features",
          error_code: "INSUFFICIENT_VALID_CANDIDATES",
          error_message: "Not enough candidates produced valid feature sets.",
          error_details: details,
          completed_at: Time.current
        )
        video.update!(
          status: "failed",
          processing_error_code: "INSUFFICIENT_VALID_CANDIDATES",
          processing_error_message: "Not enough candidates produced valid feature sets.",
          processing_error_details: details
        )
        :failed
      else
        run.update!(status: "running", current_stage: "features_complete")
        video.update!(status: "extracting_features") unless video.failed? || video.complete?
        :features_complete
      end
    end

    def record_terminal_error(video_id, processing_run_id, error)
      code = error.respond_to?(:code) && error.code.to_s != "" ? error.code.to_s : "ML_ERROR"
      message = safe_error_message(error)
      details = sanitize_error_details(error.respond_to?(:details) ? error.details : {})
      details["provider_request_id"] = error.request_id.to_s if error.respond_to?(:request_id) && error.request_id
      details["http_status"] = error.status if error.respond_to?(:status) && error.status

      ProcessingRun.transaction do
        run = ProcessingRun.lock.find(processing_run_id)
        next unless run.video_id.to_i == video_id.to_i

        video = Video.lock.find(run.video_id)
        run.update!(status: "failed", error_code: code, error_message: message, error_details: details, completed_at: Time.current)
        video.update!(status: "failed", processing_error_code: code, processing_error_message: message, processing_error_details: details)
      end
      nil
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def minimum_valid_candidates(video, processing_run: nil, available_count: nil)
      configured = ENV["ML_MIN_VALID_CANDIDATES"]
      return [ configured.to_i, 1 ].max if configured.present?

      mode = processing_run&.candidate_processing_mode.presence
      mode ||= video.duration_ms.to_i <= 60_000 ? "audit" : "repurpose"
      desired = mode == "audit" ? 1 : 5
      available_count ? [ [ desired, available_count ].min, 1 ].max : desired
    end

    def resolve_candidate_generation_version!(run)
      return run.candidate_generation_version if run.candidate_generation_version.present?

      generation_versions = run.video.candidate_clips.distinct.pluck(:generation_version)
      if generation_versions.many?
        raise Ml::Client::PermanentError.new(
          "The processing run cannot be matched to a candidate generation",
          code: "CANDIDATE_PROVENANCE_AMBIGUOUS",
          details: { "generation_count" => generation_versions.length }
        )
      end
      generation_version = generation_versions.first || ENV.fetch("ML_GENERATION_VERSION", "candidate-2")
      run.update!(candidate_generation_version: generation_version)
      generation_version
    end

    def client_for(injected)
      injected || Ml::Client.new
    end

    def source_media_payload(video)
      raise Ml::Client::PermanentError.new("The source media is missing", code: "SOURCE_MEDIA_MISSING") unless video.source_media.attached?

      {
        "signed_url" => video.source_media.url,
        "mime_type" => video.source_media.content_type.to_s
      }
    rescue ActiveStorage::FileNotFoundError => e
      raise Ml::Client::PermanentError.new("The source media is unavailable", code: "SOURCE_MEDIA_UNAVAILABLE",
        details: { "class" => e.class.name })
    end

    def request_id(video_id, processing_run_id, stage)
      "#{stage}-#{video_id}-#{processing_run_id}-#{SecureRandom.hex(8)}"
    end

    def safe_error_message(error)
      message = error.message.to_s
      message = "The media processing service returned an invalid response." if message.empty?
      message.length > 500 ? "#{message[0, 497]}..." : message
    end

    def normalize_payload(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), output| output[key.to_s] = normalize_payload(item) }
      when Array
        value.map { |item| normalize_payload(item) }
      else
        value
      end
    end

    def validate_transcription_data!(data, video_id:, transcript_version:)
      data = normalize_payload(data)
      unless data.is_a?(Hash) && data["video_id"].to_s == video_id.to_s && data["transcript_version"].to_s == transcript_version.to_s && data["segments"].is_a?(Array)
        raise Ml::Client::ContractError.new("The transcription response is invalid", code: "MALFORMED_RESPONSE")
      end

      previous_end = nil
      sequences = {}
      data["segments"].each_with_index do |segment, index|
        required = %w[sequence start_ms end_ms text words is_sentence_boundary_start is_sentence_boundary_end]
        unless segment.is_a?(Hash) && (required - segment.keys).empty?
          raise Ml::Client::ContractError.new("The transcription response is missing segment fields", code: "MALFORMED_RESPONSE")
        end
        unless segment["sequence"].is_a?(Integer) && segment["sequence"] == index && segment["start_ms"].is_a?(Integer) && segment["end_ms"].is_a?(Integer) && segment["start_ms"] < segment["end_ms"]
          raise Ml::Client::ContractError.new("The transcription response has invalid timestamps", code: "INVALID_TIMESTAMPS")
        end
        unless segment["text"].is_a?(String) && !segment["text"].strip.empty? && segment["words"].is_a?(Array)
          raise Ml::Client::ContractError.new("The transcription response has invalid text or words", code: "MALFORMED_RESPONSE")
        end
        unless [ true, false ].include?(segment["is_sentence_boundary_start"]) && [ true, false ].include?(segment["is_sentence_boundary_end"])
          raise Ml::Client::ContractError.new("The transcription response has invalid boundary flags", code: "MALFORMED_RESPONSE")
        end
        if sequences.key?(segment["sequence"]) || (previous_end && segment["start_ms"] < previous_end)
          raise Ml::Client::ContractError.new("The transcription segments are not ordered", code: "INVALID_TIMESTAMPS")
        end
        segment["words"].each do |word|
          unless word.is_a?(Hash) && %w[start_ms end_ms text].all? { |key| word.key?(key) } && word["start_ms"].is_a?(Integer) && word["end_ms"].is_a?(Integer) && word["start_ms"] < word["end_ms"] && word["start_ms"] >= segment["start_ms"] && word["end_ms"] <= segment["end_ms"] && word["text"].is_a?(String)
            raise Ml::Client::ContractError.new("The transcription response has invalid word timestamps", code: "INVALID_TIMESTAMPS")
          end
        end
        sequences[segment["sequence"]] = true
        previous_end = segment["end_ms"]
      end
      data
    end

    def validate_candidate_data!(data, video_id:, generation_version:, duration_ms:, processing_mode: "repurpose")
      data = normalize_payload(data)
      unless data.is_a?(Hash) && data["video_id"].to_s == video_id.to_s && data["generation_version"].to_s == generation_version.to_s && data["candidates"].is_a?(Array)
        raise Ml::Client::ContractError.new("The candidate response is invalid", code: "MALFORMED_RESPONSE")
      end

      sequences = {}
      boundaries = {}
      data["candidates"].each do |candidate|
        required = %w[sequence start_ms end_ms duration_ms transcript source_segment_sequences]
        unless candidate.is_a?(Hash) && (required - candidate.keys).empty?
          raise Ml::Client::ContractError.new("The candidate response is missing fields", code: "MALFORMED_RESPONSE")
        end
        unless candidate["sequence"].is_a?(Integer) && candidate["sequence"] >= 0 && candidate["start_ms"].is_a?(Integer) && candidate["end_ms"].is_a?(Integer) && candidate["start_ms"] < candidate["end_ms"]
          raise Ml::Client::ContractError.new("The candidate response has invalid timestamps", code: "INVALID_TIMESTAMPS")
        end
        expected_duration = candidate["end_ms"] - candidate["start_ms"]
        minimum_duration = processing_mode.to_s == "audit" ? 3_000 : 15_000
        unless candidate["duration_ms"] == expected_duration && candidate["duration_ms"].between?(minimum_duration, 60_000)
          range = processing_mode.to_s == "audit" ? "3 and 60" : "15 and 60"
          raise Ml::Client::ContractError.new("Candidate duration must be between #{range} seconds", code: "INVALID_CANDIDATE_DURATION")
        end
        if duration_ms && candidate["end_ms"] > duration_ms
          raise Ml::Client::ContractError.new("Candidate exceeds source duration", code: "INVALID_TIMESTAMPS")
        end
        unless candidate["transcript"].is_a?(String) && !candidate["transcript"].strip.empty? && candidate["source_segment_sequences"].is_a?(Array) && !candidate["source_segment_sequences"].empty? && candidate["source_segment_sequences"].all? { |item| item.is_a?(Integer) && item >= 0 }
          raise Ml::Client::ContractError.new("The candidate response has invalid transcript metadata", code: "MALFORMED_RESPONSE")
        end
        key = [ candidate["start_ms"], candidate["end_ms"] ]
        if sequences.key?(candidate["sequence"]) || boundaries.key?(key)
          raise Ml::Client::ContractError.new("Candidate sequences and boundaries must be unique", code: "DUPLICATE_CANDIDATE")
        end
        sequences[candidate["sequence"]] = true
        boundaries[key] = true
      end
      data
    end

    def validate_feature_data!(data, video_id:, candidate_id:, feature_version:)
      data = normalize_payload(data)
      required = %w[video_id candidate_id feature_version model_version prompt_version semantic audio visual structural capability_warnings]
      unless data.is_a?(Hash) && (required - data.keys).empty? && data["video_id"].to_s == video_id.to_s && data["candidate_id"].to_s == candidate_id.to_s && data["feature_version"].to_s == feature_version.to_s
        raise Ml::Client::ContractError.new("The feature response is invalid", code: "MALFORMED_RESPONSE")
      end
      unless (data.keys - required).empty?
        raise Ml::Client::ContractError.new("The feature response contains unknown fields", code: "MALFORMED_RESPONSE")
      end
      unless data["model_version"].is_a?(String) && !data["model_version"].empty? && (data["prompt_version"].nil? || (data["prompt_version"].is_a?(String) && !data["prompt_version"].empty?))
        raise Ml::Client::ContractError.new("The feature response has invalid model provenance", code: "MALFORMED_RESPONSE")
      end
      unless data["capability_warnings"].is_a?(Array) && data["capability_warnings"].all? { |warning| warning.is_a?(String) && !warning.empty? }
        raise Ml::Client::ContractError.new("The feature response has invalid capability warnings", code: "MALFORMED_RESPONSE")
      end

      semantic_keys = %w[hook_strength standalone_clarity information_density novelty emotional_intensity quotability payoff_strength story_completeness technical_depth call_to_action_presence topic content_type hook_type]
      validate_feature_object!(data["semantic"], semantic_keys, "semantic")
      %w[hook_strength standalone_clarity information_density novelty emotional_intensity quotability payoff_strength story_completeness technical_depth call_to_action_presence].each do |key|
        validate_feature_unit_float!(data["semantic"][key], "semantic.#{key}")
      end
      validate_feature_string!(data["semantic"]["topic"], "semantic.topic")
      validate_feature_enum!(data["semantic"]["content_type"], %w[story tutorial opinion project_demo career_advice coding_tip educational announcement other], "semantic.content_type")
      validate_feature_enum!(data["semantic"]["hook_type"], %w[question contrarian surprising_claim personal_story result_first problem curiosity_gap none], "semantic.hook_type")

      audio_keys = %w[words_per_minute average_audio_energy energy_variance energy_change_at_hook silence_ratio longest_pause_ms pause_frequency]
      validate_feature_object!(data["audio"], audio_keys, "audio")
      validate_feature_number!(data["audio"]["words_per_minute"], "audio.words_per_minute")
      %w[average_audio_energy energy_variance energy_change_at_hook silence_ratio pause_frequency].each do |key|
        validate_feature_unit_float!(data["audio"][key], "audio.#{key}")
      end
      validate_feature_integer!(data["audio"]["longest_pause_ms"], "audio.longest_pause_ms")

      visual_keys = %w[face_presence_ratio visual_motion scene_change_rate screen_recording_ratio camera_change_frequency sample_count]
      validate_feature_object!(data["visual"], visual_keys, "visual")
      %w[face_presence_ratio visual_motion scene_change_rate screen_recording_ratio camera_change_frequency].each do |key|
        validate_feature_unit_float!(data["visual"][key], "visual.#{key}")
      end
      validate_feature_integer!(data["visual"]["sample_count"], "visual.sample_count")

      structural_keys = %w[time_to_main_point_ms intro_length_ms sentence_completeness hook_to_payoff_time_ms dead_air_start_ms dead_air_end_ms]
      validate_feature_object!(data["structural"], structural_keys, "structural")
      %w[time_to_main_point_ms intro_length_ms hook_to_payoff_time_ms dead_air_start_ms dead_air_end_ms].each do |key|
        validate_feature_integer!(data["structural"][key], "structural.#{key}")
      end
      validate_feature_unit_float!(data["structural"]["sentence_completeness"], "structural.sentence_completeness")
      data
    end

    def validate_rank_data!(data, video_id:, feature_version:, scorer_version:, candidate_ids:, expected_weights: nil)
      data = normalize_payload(data)
      required = %w[video_id feature_version scorer_version ranked_candidates]
      unless data.is_a?(Hash) && (required - data.keys).empty? && data["video_id"].to_s == video_id.to_s && data["feature_version"].to_s == feature_version.to_s && data["scorer_version"].to_s == scorer_version.to_s
        raise Ml::Client::ContractError.new("The ranking response is invalid", code: "MALFORMED_RESPONSE")
      end
      raise Ml::Client::ContractError.new("The ranking response contains unknown fields", code: "MALFORMED_RESPONSE") unless (data.keys - required).empty?
      ranked = data["ranked_candidates"]
      unless ranked.is_a?(Array) && ranked.length.between?(1, 40)
        raise Ml::Client::ContractError.new("The ranking response has no candidates", code: "MALFORMED_RESPONSE")
      end

      expected_ids = candidate_ids.map(&:to_s).sort
      response_ids = []
      ranks = []
      ranked.each do |candidate|
        required_candidate = %w[candidate_id rank clip_score components component_details]
        unless candidate.is_a?(Hash) && (required_candidate - candidate.keys).empty? && (candidate.keys - required_candidate).empty?
          raise Ml::Client::ContractError.new("The ranking response candidate is invalid", code: "MALFORMED_RESPONSE")
        end
        unless candidate["candidate_id"].is_a?(String) && !candidate["candidate_id"].empty? && candidate["rank"].is_a?(Integer) && candidate["rank"] >= 1 && candidate["clip_score"].is_a?(Numeric) && candidate["clip_score"].between?(0.0, 100.0)
          raise Ml::Client::ContractError.new("The ranking response candidate has invalid rank or score", code: "MALFORMED_RESPONSE")
        end
        component_keys = %w[content_quality hook delivery pacing visual_engagement standalone_clarity]
        components = candidate["components"]
        unless components.is_a?(Hash) && (component_keys - components.keys).empty? && (components.keys - component_keys).empty? && component_keys.all? { |key| components[key].is_a?(Numeric) && components[key].between?(0.0, 100.0) }
          raise Ml::Client::ContractError.new("The ranking response components are invalid", code: "MALFORMED_RESPONSE")
        end
        details = validate_component_details!(candidate["component_details"])
        if expected_weights && details.any? { |key, value| value["weight"] != expected_weights[key] }
          raise Ml::Client::ContractError.new("The ranking response weights do not match the frozen config", code: "RESPONSE_MISMATCH")
        end
        response_ids << candidate["candidate_id"]
        ranks << candidate["rank"]
      end
      unless response_ids.uniq.length == response_ids.length && ranks.uniq.length == ranks.length && ranks.sort == (1..ranked.length).to_a && response_ids.map(&:to_s).sort == expected_ids
        raise Ml::Client::ContractError.new("The ranking response candidates or ranks do not match the request", code: "RESPONSE_MISMATCH")
      end
      data
    end

    def validate_component_details!(details)
      keys = %w[semantic hook structural delivery visual]
      unless details.is_a?(Hash) && details.keys.map(&:to_s).sort == keys.sort
        raise Ml::Client::ContractError.new("The ranking response component details are invalid", code: "MALFORMED_RESPONSE")
      end
      details.each do |key, value|
        unless key.is_a?(String) && value.is_a?(Hash) && value.keys.map(&:to_s).sort == %w[weight normalized].sort && value["weight"].is_a?(Numeric) && value["normalized"].is_a?(Numeric) && value["weight"].between?(0.0, 1.0) && value["normalized"].between?(0.0, 1.0)
          raise Ml::Client::ContractError.new("The ranking response component details are invalid", code: "MALFORMED_RESPONSE")
        end
      end
      details
    end

    def validate_feature_object!(value, keys, name)
      unless value.is_a?(Hash) && (keys - value.keys).empty? && (value.keys - keys).empty?
        raise Ml::Client::ContractError.new("#{name} feature object is invalid", code: "MALFORMED_RESPONSE")
      end
    end

    def validate_feature_string!(value, name)
      return if value.is_a?(String) && !value.empty?

      raise Ml::Client::ContractError.new("#{name} must be a non-empty string", code: "MALFORMED_RESPONSE")
    end

    def validate_feature_number!(value, name)
      return if value.is_a?(Numeric) && value >= 0

      raise Ml::Client::ContractError.new("#{name} must be a non-negative number", code: "MALFORMED_RESPONSE")
    end

    def validate_feature_integer!(value, name)
      return if value.is_a?(Integer) && value >= 0

      raise Ml::Client::ContractError.new("#{name} must be a non-negative integer", code: "MALFORMED_RESPONSE")
    end

    def validate_feature_unit_float!(value, name)
      return if value.is_a?(Numeric) && value.between?(0.0, 1.0)

      raise Ml::Client::ContractError.new("#{name} must be between 0 and 1", code: "MALFORMED_RESPONSE")
    end

    def validate_feature_enum!(value, allowed, name)
      return if value.is_a?(String) && allowed.include?(value)

      raise Ml::Client::ContractError.new("#{name} contains an unsupported value", code: "MALFORMED_RESPONSE")
    end

    def sanitize_error_details(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), output|
          key_string = key.to_s
          next if key_string.match?(/token|secret|authorization|signed_url|password/i)

          output[key_string] = sanitize_error_details(item)
        end
      when Array
        value.first(20).map { |item| sanitize_error_details(item) }
      when String
        value.length > 500 ? "#{value[0, 497]}..." : value
      when Numeric, TrueClass, FalseClass, NilClass
        value
      else
        value.to_s[0, 500]
      end
    end
  end
end
