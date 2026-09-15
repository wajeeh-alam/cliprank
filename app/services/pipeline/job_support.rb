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
      "ranking" => 70,
      "complete" => 100
    }.freeze

    private

    def load_processing_records(video_id, processing_run_id)
      run = ProcessingRun.find(processing_run_id)
      raise ActiveRecord::RecordNotFound, "processing run does not belong to video" unless run.video_id.to_i == video_id.to_i

      [run, run.video]
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
        unless [true, false].include?(segment["is_sentence_boundary_start"]) && [true, false].include?(segment["is_sentence_boundary_end"])
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

    def validate_candidate_data!(data, video_id:, generation_version:, duration_ms:)
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
        unless candidate["duration_ms"] == expected_duration && candidate["duration_ms"].between?(15_000, 60_000)
          raise Ml::Client::ContractError.new("Candidate duration must be between 15 and 60 seconds", code: "INVALID_CANDIDATE_DURATION")
        end
        if duration_ms && candidate["end_ms"] > duration_ms
          raise Ml::Client::ContractError.new("Candidate exceeds source duration", code: "INVALID_TIMESTAMPS")
        end
        unless candidate["transcript"].is_a?(String) && !candidate["transcript"].strip.empty? && candidate["source_segment_sequences"].is_a?(Array) && !candidate["source_segment_sequences"].empty? && candidate["source_segment_sequences"].all? { |item| item.is_a?(Integer) && item >= 0 }
          raise Ml::Client::ContractError.new("The candidate response has invalid transcript metadata", code: "MALFORMED_RESPONSE")
        end
        key = [candidate["start_ms"], candidate["end_ms"]]
        if sequences.key?(candidate["sequence"]) || boundaries.key?(key)
          raise Ml::Client::ContractError.new("Candidate sequences and boundaries must be unique", code: "DUPLICATE_CANDIDATE")
        end
        sequences[candidate["sequence"]] = true
        boundaries[key] = true
      end
      data
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
