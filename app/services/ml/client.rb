require "json"
require "net/http"
require "securerandom"
require "timeout"
require "uri"

module Ml
  # Small, deliberately boring HTTP boundary for the internal ML service.  The
  # service is not allowed to return an unversioned or partially validated
  # result to the rest of the Rails application.
  class Client
    CONTRACT_VERSION = "1.0".freeze
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 300
    DEFAULT_WRITE_TIMEOUT = 30

    class Error < StandardError
      attr_reader :code, :details, :request_id, :status, :retryable

      def initialize(message = nil, code: nil, details: {}, request_id: nil, status: nil, retryable: false)
        super(message)
        @code = code
        @details = details.is_a?(Hash) ? details : {}
        @request_id = request_id
        @status = status
        @retryable = retryable
      end

      def retryable?
        @retryable
      end
    end

    class RetryableError < Error
      def initialize(message = nil, **options)
        options[:retryable] = true unless options.key?(:retryable)
        super(message, **options)
      end
    end

    class PermanentError < Error
      def initialize(message = nil, **options)
        options[:retryable] = false unless options.key?(:retryable)
        super(message, **options)
      end
    end

    class ConfigurationError < PermanentError; end
    class ContractError < PermanentError; end
    class InvalidRequestError < PermanentError; end
    class TimeoutError < RetryableError; end
    class TransportError < RetryableError; end
    TransientError = RetryableError
    InvalidResponseError = ContractError

    # HTTP errors retain their HTTP-specific type while remaining retryable at
    # the job boundary. Jobs inspect #retryable? before deciding whether to
    # re-raise for Active Job's retry handler.
    class HttpError < RetryableError; end

    def initialize(base_url: ENV["ML_BASE_URL"], service_token: ENV["ML_SERVICE_TOKEN"],
                   open_timeout: ENV.fetch("ML_OPEN_TIMEOUT", DEFAULT_OPEN_TIMEOUT).to_i,
                   read_timeout: ENV.fetch("ML_READ_TIMEOUT", DEFAULT_READ_TIMEOUT).to_i,
                   write_timeout: ENV.fetch("ML_WRITE_TIMEOUT", DEFAULT_WRITE_TIMEOUT).to_i,
                   http_class: Net::HTTP)
      raise ConfigurationError.new("ML_BASE_URL is not configured", code: "ML_NOT_CONFIGURED") if base_url.to_s.strip.empty?
      raise ConfigurationError.new("ML_SERVICE_TOKEN is not configured", code: "ML_NOT_CONFIGURED") if service_token.to_s.strip.empty?

      @base_uri = URI.parse(base_url.to_s)
      unless %w[http https].include?(@base_uri.scheme) && @base_uri.host
        raise ConfigurationError.new("ML_BASE_URL must be an HTTP(S) URL", code: "ML_NOT_CONFIGURED")
      end

      @service_token = service_token.to_s
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
      @http_class = http_class
    rescue URI::InvalidURIError => e
      raise ConfigurationError.new("ML_BASE_URL is invalid", code: "ML_NOT_CONFIGURED", details: { "reason" => e.message })
    end

    def transcribe(payload = nil, request_id: nil, idempotency_key: nil, **attributes)
      data = payload || attributes
      response = post("/internal/api/v1/transcriptions", data, request_id: request_id, idempotency_key: idempotency_key)
      validate_transcription!(response, expected_video_id: data["video_id"] || data[:video_id],
        expected_version: data["transcript_version"] || data[:transcript_version])
    end

    def generate_candidates(payload = nil, request_id: nil, idempotency_key: nil, **attributes)
      data = payload || attributes
      response = post("/internal/api/v1/candidates/generate", data, request_id: request_id, idempotency_key: idempotency_key)
      validate_candidates!(response, expected_video_id: data["video_id"] || data[:video_id],
        expected_version: data["generation_version"] || data[:generation_version],
        processing_mode: data["processing_mode"] || data[:processing_mode] || "repurpose")
    end

    def extract_features(payload = nil, request_id: nil, idempotency_key: nil, **attributes)
      data = payload || attributes
      response = post("/internal/api/v1/candidates/features", data, request_id: request_id, idempotency_key: idempotency_key)
      validate_features!(
        response,
        expected_video_id: data["video_id"] || data[:video_id],
        expected_candidate_id: data["candidate_id"] || data[:candidate_id],
        expected_version: data["feature_version"] || data[:feature_version]
      )
    end
    alias extract_candidate_features extract_features

    def rank(payload = nil, request_id: nil, idempotency_key: nil, **attributes)
      data = payload || attributes
      response = post("/internal/api/v1/rank", data, request_id: request_id, idempotency_key: idempotency_key)
      validate_rank!(
        response,
        expected_video_id: data["video_id"] || data[:video_id],
        expected_feature_version: data["feature_version"] || data[:feature_version],
        expected_scorer_version: data["scorer_version"] || data[:scorer_version],
        expected_candidate_ids: Array(data["candidates"] || data[:candidates]).each_with_object([]) do |candidate, ids|
          ids << (candidate["candidate_id"] || candidate[:candidate_id]) if candidate.is_a?(Hash)
        end
      )
    end

    private

    def post(path, data, request_id:, idempotency_key:)
      request_id = SecureRandom.uuid if request_id.nil?
      request_id = request_id.to_s.strip
      idempotency_key = idempotency_key.to_s.strip
      raise InvalidRequestError.new("request_id is required", code: "INVALID_REQUEST") if request_id.empty?
      raise InvalidRequestError.new("idempotency_key is required", code: "INVALID_REQUEST") if idempotency_key.empty?
      raise InvalidRequestError.new("request payload must be an object", code: "INVALID_REQUEST") unless data.is_a?(Hash)

      body = JSON.generate({ "contract_version" => CONTRACT_VERSION }.merge(stringify_keys(data)))
      uri = endpoint_uri(path)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@service_token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["X-Request-Id"] = request_id
      request["Idempotency-Key"] = idempotency_key
      request.body = body

      response = execute(uri, request)
      parse_response(response, expected_request_id: request_id, expected_idempotency_key: idempotency_key)
    end

    def execute(uri, request)
      http = @http_class.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https" if http.respond_to?(:use_ssl=)
      http.open_timeout = @open_timeout if http.respond_to?(:open_timeout=)
      http.read_timeout = @read_timeout if http.respond_to?(:read_timeout=)
      http.write_timeout = @write_timeout if http.respond_to?(:write_timeout=)
      http.start { |connection| connection.request(request) }
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error => e
      raise TimeoutError.new("The ML service timed out", code: "ML_TIMEOUT", details: { "class" => e.class.name })
    rescue IOError, EOFError, SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      raise TransportError.new("The ML service could not be reached", code: "ML_UNAVAILABLE", details: { "class" => e.class.name })
    end

    def parse_response(response, expected_request_id:, expected_idempotency_key:)
      status = response.code.to_i
      parsed = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError => e
        raise ContractError.new("The ML service returned invalid JSON", code: "MALFORMED_RESPONSE",
          status: status, details: { "reason" => e.message })
      end

      unless status.between?(200, 299)
        error = parsed.is_a?(Hash) ? parsed["error"] : nil
        error = {} unless error.is_a?(Hash)
        if error.key?("retryable") && ![ true, false ].include?(error["retryable"])
          raise ContractError.new("ML error retryable must be boolean", code: "MALFORMED_RESPONSE", status: status)
        end
        retryable = if [ true, false ].include?(error["retryable"])
          error["retryable"]
        else
          [ 408, 429 ].include?(status) || status >= 500
        end
        raise HttpError.new(
          error["message"].to_s.empty? ? "The ML service returned HTTP #{status}" : error["message"].to_s,
          code: error["code"].to_s.empty? ? "ML_HTTP_#{status}" : error["code"],
          details: error["details"].is_a?(Hash) ? error["details"] : {},
          request_id: parsed.is_a?(Hash) ? parsed["request_id"] : nil, status: status, retryable: retryable
        )
      end

      validate_envelope!(parsed, expected_request_id: expected_request_id, expected_idempotency_key: expected_idempotency_key)
      parsed["data"]
    end

    def validate_envelope!(payload, expected_request_id:, expected_idempotency_key:)
      unless payload.is_a?(Hash)
        raise ContractError.new("The ML service response must be a JSON object", code: "MALFORMED_RESPONSE")
      end

      required = %w[contract_version request_id idempotency_key data]
      reject_unknown_keys!(payload, required + [ "warnings" ])
      missing = required.reject { |key| payload.key?(key) }
      unless missing.empty?
        raise ContractError.new("The ML service response is missing required fields", code: "MALFORMED_RESPONSE",
          details: { "missing" => missing })
      end
      unless payload["contract_version"] == CONTRACT_VERSION
        raise ContractError.new("Unsupported ML contract version", code: "UNSUPPORTED_CONTRACT_VERSION",
          details: { "received" => payload["contract_version"], "expected" => CONTRACT_VERSION })
      end
      unless payload["request_id"].is_a?(String) && payload["request_id"] == expected_request_id
        raise ContractError.new("ML response request_id does not match the request", code: "REQUEST_ID_MISMATCH")
      end
      unless payload["idempotency_key"].is_a?(String) && payload["idempotency_key"] == expected_idempotency_key
        raise ContractError.new("ML response idempotency_key does not match the request", code: "IDEMPOTENCY_KEY_MISMATCH")
      end
      unless payload["data"].is_a?(Hash)
        raise ContractError.new("The ML response data must be an object", code: "MALFORMED_RESPONSE")
      end
      if payload.key?("warnings") && (!payload["warnings"].is_a?(Array) || !payload["warnings"].all? { |warning| warning.is_a?(String) && !warning.empty? })
        raise ContractError.new("ML response warnings must be non-empty strings", code: "MALFORMED_RESPONSE")
      end
    end

    def validate_transcription!(data, expected_video_id:, expected_version:)
      require_data_keys!(data, %w[video_id transcript_version language segments])
      reject_unknown_keys!(data, %w[video_id transcript_version language segments])
      validate_string_match!(data["video_id"], expected_video_id, "video_id")
      validate_string_match!(data["transcript_version"], expected_version, "transcript_version")
      unless data["language"].nil? || data["language"].is_a?(String)
        raise ContractError.new("transcription language must be a string or null", code: "MALFORMED_RESPONSE")
      end
      segments = data["segments"]
      raise ContractError.new("transcription segments must be an array", code: "MALFORMED_RESPONSE") unless segments.is_a?(Array)

      previous_end = nil
      sequences = {}
      segments.each_with_index do |segment, index|
        require_data_keys!(segment, %w[sequence start_ms end_ms text words is_sentence_boundary_start is_sentence_boundary_end])
        reject_unknown_keys!(segment, %w[sequence start_ms end_ms text words is_sentence_boundary_start is_sentence_boundary_end])
        validate_integer!(segment["sequence"], "segment sequence")
        unless segment["sequence"] == index
          raise ContractError.new("transcription segment sequence must be contiguous", code: "INVALID_TIMESTAMPS")
        end
        validate_ms_range!(segment["start_ms"], segment["end_ms"], "segment")
        unless segment["text"].is_a?(String) && !segment["text"].strip.empty?
          raise ContractError.new("segment text must be a non-empty string", code: "MALFORMED_RESPONSE")
        end
        unless segment["words"].is_a?(Array)
          raise ContractError.new("segment words must be an array", code: "MALFORMED_RESPONSE")
        end
        segment["words"].each do |word|
          require_data_keys!(word, %w[start_ms end_ms text])
          reject_unknown_keys!(word, %w[start_ms end_ms text])
          validate_ms_range!(word["start_ms"], word["end_ms"], "word")
          unless word["start_ms"] >= segment["start_ms"] && word["end_ms"] <= segment["end_ms"]
            raise ContractError.new("word timestamps must be inside the segment", code: "INVALID_TIMESTAMPS")
          end
          raise ContractError.new("word text must be a string", code: "MALFORMED_RESPONSE") unless word["text"].is_a?(String)
        end
        unless [ true, false ].include?(segment["is_sentence_boundary_start"]) && [ true, false ].include?(segment["is_sentence_boundary_end"])
          raise ContractError.new("segment sentence boundary flags must be booleans", code: "MALFORMED_RESPONSE")
        end
        if sequences.key?(segment["sequence"]) || (previous_end && segment["start_ms"] < previous_end)
          raise ContractError.new("transcription segments must be ordered and non-overlapping", code: "INVALID_TIMESTAMPS")
        end
        sequences[segment["sequence"]] = true
        previous_end = segment["end_ms"]
      end
      data
    end

    def validate_candidates!(data, expected_video_id:, expected_version:, processing_mode: "repurpose")
      require_data_keys!(data, %w[video_id generation_version candidates])
      reject_unknown_keys!(data, %w[video_id generation_version candidates])
      validate_string_match!(data["video_id"], expected_video_id, "video_id")
      validate_string_match!(data["generation_version"], expected_version, "generation_version")
      candidates = data["candidates"]
      raise ContractError.new("candidates must be an array", code: "MALFORMED_RESPONSE") unless candidates.is_a?(Array)

      boundaries = {}
      sequences = {}
      candidates.each do |candidate|
        require_data_keys!(candidate, %w[sequence start_ms end_ms duration_ms transcript source_segment_sequences])
        reject_unknown_keys!(candidate, %w[sequence start_ms end_ms duration_ms transcript source_segment_sequences])
        validate_integer!(candidate["sequence"], "candidate sequence")
        validate_ms_range!(candidate["start_ms"], candidate["end_ms"], "candidate")
        validate_integer!(candidate["duration_ms"], "candidate duration_ms")
        minimum_duration = processing_mode.to_s == "audit" ? 3_000 : 15_000
        unless candidate["duration_ms"] == candidate["end_ms"] - candidate["start_ms"] && candidate["duration_ms"].between?(minimum_duration, 60_000)
          range = processing_mode.to_s == "audit" ? "3–60" : "15–60"
          raise ContractError.new("candidate duration must equal its interval and be #{range} seconds", code: "INVALID_CANDIDATE_DURATION")
        end
        unless candidate["transcript"].is_a?(String) && !candidate["transcript"].strip.empty?
          raise ContractError.new("candidate transcript must be a non-empty string", code: "MALFORMED_RESPONSE")
        end
        unless candidate["source_segment_sequences"].is_a?(Array) && !candidate["source_segment_sequences"].empty? && candidate["source_segment_sequences"].all? { |value| value.is_a?(Integer) && value >= 0 }
          raise ContractError.new("candidate source_segment_sequences must be an array of non-negative integers", code: "MALFORMED_RESPONSE")
        end
        key = [ candidate["start_ms"], candidate["end_ms"] ]
        if boundaries.key?(key) || sequences.key?(candidate["sequence"])
          raise ContractError.new("candidate sequences and boundaries must be unique", code: "DUPLICATE_CANDIDATE")
        end
        boundaries[key] = true
        sequences[candidate["sequence"]] = true
      end
      data
    end

    def validate_features!(data, expected_video_id:, expected_candidate_id:, expected_version:)
      require_data_keys!(data, %w[video_id candidate_id feature_version model_version prompt_version semantic audio visual structural capability_warnings])
      reject_unknown_keys!(data, %w[video_id candidate_id feature_version model_version prompt_version semantic audio visual structural capability_warnings])
      validate_string_match!(data["video_id"], expected_video_id, "video_id")
      validate_string_match!(data["candidate_id"], expected_candidate_id, "candidate_id")
      validate_string_match!(data["feature_version"], expected_version, "feature_version")
      validate_non_empty_string!(data["model_version"], "model_version")
      unless data["prompt_version"].nil? || (data["prompt_version"].is_a?(String) && !data["prompt_version"].empty?)
        raise ContractError.new("prompt_version must be a string or null", code: "MALFORMED_RESPONSE")
      end
      unless data["capability_warnings"].is_a?(Array) && data["capability_warnings"].all? { |warning| warning.is_a?(String) && !warning.empty? }
        raise ContractError.new("capability_warnings must contain non-empty strings", code: "MALFORMED_RESPONSE")
      end

      semantic = data["semantic"]
      require_data_keys!(semantic, %w[hook_strength standalone_clarity information_density novelty emotional_intensity quotability payoff_strength story_completeness technical_depth call_to_action_presence topic content_type hook_type])
      reject_unknown_keys!(semantic, %w[hook_strength standalone_clarity information_density novelty emotional_intensity quotability payoff_strength story_completeness technical_depth call_to_action_presence topic content_type hook_type])
      %w[hook_strength standalone_clarity information_density novelty emotional_intensity quotability payoff_strength story_completeness technical_depth call_to_action_presence].each do |key|
        validate_unit_float!(semantic[key], "semantic.#{key}")
      end
      validate_non_empty_string!(semantic["topic"], "semantic.topic")
      validate_enum!(semantic["content_type"], %w[story tutorial opinion project_demo career_advice coding_tip educational announcement other], "semantic.content_type")
      validate_enum!(semantic["hook_type"], %w[question contrarian surprising_claim personal_story result_first problem curiosity_gap none], "semantic.hook_type")

      audio = data["audio"]
      require_data_keys!(audio, %w[words_per_minute average_audio_energy energy_variance energy_change_at_hook silence_ratio longest_pause_ms pause_frequency])
      reject_unknown_keys!(audio, %w[words_per_minute average_audio_energy energy_variance energy_change_at_hook silence_ratio longest_pause_ms pause_frequency])
      validate_non_negative_number!(audio["words_per_minute"], "audio.words_per_minute")
      %w[average_audio_energy energy_variance energy_change_at_hook silence_ratio pause_frequency].each do |key|
        validate_unit_float!(audio[key], "audio.#{key}")
      end
      validate_integer!(audio["longest_pause_ms"], "audio.longest_pause_ms")

      visual = data["visual"]
      require_data_keys!(visual, %w[face_presence_ratio visual_motion scene_change_rate screen_recording_ratio camera_change_frequency sample_count])
      reject_unknown_keys!(visual, %w[face_presence_ratio visual_motion scene_change_rate screen_recording_ratio camera_change_frequency sample_count])
      %w[face_presence_ratio visual_motion scene_change_rate screen_recording_ratio camera_change_frequency].each do |key|
        validate_unit_float!(visual[key], "visual.#{key}")
      end
      validate_integer!(visual["sample_count"], "visual.sample_count")

      structural = data["structural"]
      require_data_keys!(structural, %w[time_to_main_point_ms intro_length_ms sentence_completeness hook_to_payoff_time_ms dead_air_start_ms dead_air_end_ms])
      reject_unknown_keys!(structural, %w[time_to_main_point_ms intro_length_ms sentence_completeness hook_to_payoff_time_ms dead_air_start_ms dead_air_end_ms])
      %w[time_to_main_point_ms intro_length_ms hook_to_payoff_time_ms dead_air_start_ms dead_air_end_ms].each do |key|
        validate_integer!(structural[key], "structural.#{key}")
      end
      validate_unit_float!(structural["sentence_completeness"], "structural.sentence_completeness")
      data
    end

    def validate_rank!(data, expected_video_id:, expected_feature_version:, expected_scorer_version:, expected_candidate_ids:)
      require_data_keys!(data, %w[video_id feature_version scorer_version ranked_candidates])
      reject_unknown_keys!(data, %w[video_id feature_version scorer_version ranked_candidates])
      validate_string_match!(data["video_id"], expected_video_id, "video_id")
      validate_string_match!(data["feature_version"], expected_feature_version, "feature_version")
      validate_string_match!(data["scorer_version"], expected_scorer_version, "scorer_version")
      candidates = data["ranked_candidates"]
      raise ContractError.new("ranked_candidates must contain 1–40 items", code: "MALFORMED_RESPONSE") unless candidates.is_a?(Array) && candidates.length.between?(1, 40)

      expected_ids = expected_candidate_ids.compact.map(&:to_s).sort
      response_ids = []
      ranks = []
      candidates.each do |candidate|
        require_data_keys!(candidate, %w[candidate_id rank clip_score components component_details])
        reject_unknown_keys!(candidate, %w[candidate_id rank clip_score components component_details])
        validate_non_empty_string!(candidate["candidate_id"], "ranked candidate_id")
        validate_positive_integer!(candidate["rank"], "ranked rank")
        validate_score!(candidate["clip_score"], "clip_score")
        components = candidate["components"]
        component_keys = %w[content_quality hook delivery pacing visual_engagement standalone_clarity]
        require_data_keys!(components, component_keys)
        reject_unknown_keys!(components, component_keys)
        component_keys.each { |key| validate_score!(components[key], "components.#{key}") }
        validate_component_details!(candidate["component_details"])
        response_ids << candidate["candidate_id"].to_s
        ranks << candidate["rank"]
      end
      if response_ids.uniq.length != response_ids.length || ranks.uniq.length != ranks.length || ranks.sort != (1..candidates.length).to_a
        raise ContractError.new("ranked candidates must have unique contiguous ranks and ids", code: "MALFORMED_RESPONSE")
      end
      unless expected_ids.empty? || response_ids.sort == expected_ids
        raise ContractError.new("ranked candidate ids do not match the request", code: "RESPONSE_MISMATCH")
      end
      data
    end

    def require_data_keys!(object, keys)
      unless object.is_a?(Hash)
        raise ContractError.new("ML response item must be an object", code: "MALFORMED_RESPONSE")
      end
      missing = keys.reject { |key| object.key?(key) }
      return if missing.empty?

      raise ContractError.new("ML response item is missing required fields", code: "MALFORMED_RESPONSE",
        details: { "missing" => missing })
    end

    def reject_unknown_keys!(object, keys)
      unknown = object.keys.map(&:to_s) - keys
      return if unknown.empty?

      raise ContractError.new("ML response contains unknown fields", code: "MALFORMED_RESPONSE",
        details: { "unknown" => unknown })
    end

    def validate_string_match!(actual, expected, name)
      raise ContractError.new("#{name} must be a string", code: "MALFORMED_RESPONSE") unless actual.is_a?(String)
      return if expected.nil? || actual == expected.to_s

      raise ContractError.new("ML response #{name} does not match the request", code: "RESPONSE_MISMATCH")
    end

    def validate_non_empty_string!(value, name)
      return if value.is_a?(String) && !value.empty?

      raise ContractError.new("#{name} must be a non-empty string", code: "MALFORMED_RESPONSE")
    end

    def validate_non_negative_number!(value, name)
      return if value.is_a?(Numeric) && value >= 0

      raise ContractError.new("#{name} must be a non-negative number", code: "MALFORMED_RESPONSE")
    end

    def validate_unit_float!(value, name)
      return if value.is_a?(Numeric) && value.between?(0.0, 1.0)

      raise ContractError.new("#{name} must be between 0 and 1", code: "MALFORMED_RESPONSE")
    end

    def validate_enum!(value, allowed, name)
      return if value.is_a?(String) && allowed.include?(value)

      raise ContractError.new("#{name} contains an unsupported value", code: "MALFORMED_RESPONSE")
    end

    def validate_positive_integer!(value, name)
      return if value.is_a?(Integer) && value >= 1

      raise ContractError.new("#{name} must be a positive integer", code: "MALFORMED_RESPONSE")
    end

    def validate_component_details!(details)
      keys = %w[semantic hook structural delivery visual]
      unless details.is_a?(Hash) && details.keys.map(&:to_s).sort == keys.sort
        raise ContractError.new("component_details must contain the five scoring components", code: "MALFORMED_RESPONSE")
      end
      details.each do |key, value|
        unless key.is_a?(String) && value.is_a?(Hash) && value.keys.map(&:to_s).sort == %w[weight normalized].sort && value["weight"].is_a?(Numeric) && value["normalized"].is_a?(Numeric) && value["weight"].between?(0.0, 1.0) && value["normalized"].between?(0.0, 1.0)
          raise ContractError.new("component_details values must contain unit weight and normalized values", code: "MALFORMED_RESPONSE")
        end
      end
    end

    def validate_score!(value, name)
      return if value.is_a?(Numeric) && value.between?(0.0, 100.0)

      raise ContractError.new("#{name} must be between 0 and 100", code: "MALFORMED_RESPONSE")
    end

    def validate_integer!(value, name)
      return if value.is_a?(Integer) && value >= 0

      raise ContractError.new("#{name} must be a non-negative integer", code: "INVALID_TIMESTAMPS")
    end

    def validate_ms_range!(start_ms, end_ms, name)
      validate_integer!(start_ms, "#{name} start_ms")
      validate_integer!(end_ms, "#{name} end_ms")
      return if start_ms < end_ms

      raise ContractError.new("#{name} start_ms must be less than end_ms", code: "INVALID_TIMESTAMPS")
    end

    def endpoint_uri(path)
      uri = @base_uri.dup
      base_path = @base_uri.path.to_s.sub(%r{/$}, "")
      uri.path = "#{base_path}#{path}"
      uri.query = nil
      uri
    end

    def stringify_keys(hash)
      hash.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value.is_a?(Hash) ? stringify_keys(value) : value
      end
    end
  end
end
