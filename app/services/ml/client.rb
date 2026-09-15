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
        expected_version: data["generation_version"] || data[:generation_version])
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
        if error.key?("retryable") && ![true, false].include?(error["retryable"])
          raise ContractError.new("ML error retryable must be boolean", code: "MALFORMED_RESPONSE", status: status)
        end
        retryable = if [true, false].include?(error["retryable"])
          error["retryable"]
        else
          [408, 429].include?(status) || status >= 500
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
      reject_unknown_keys!(payload, required + ["warnings"])
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
        unless [true, false].include?(segment["is_sentence_boundary_start"]) && [true, false].include?(segment["is_sentence_boundary_end"])
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

    def validate_candidates!(data, expected_video_id:, expected_version:)
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
        unless candidate["duration_ms"] == candidate["end_ms"] - candidate["start_ms"] && candidate["duration_ms"].between?(15_000, 60_000)
          raise ContractError.new("candidate duration must equal its interval and be 15–60 seconds", code: "INVALID_CANDIDATE_DURATION")
        end
        unless candidate["transcript"].is_a?(String) && !candidate["transcript"].strip.empty?
          raise ContractError.new("candidate transcript must be a non-empty string", code: "MALFORMED_RESPONSE")
        end
        unless candidate["source_segment_sequences"].is_a?(Array) && !candidate["source_segment_sequences"].empty? && candidate["source_segment_sequences"].all? { |value| value.is_a?(Integer) && value >= 0 }
          raise ContractError.new("candidate source_segment_sequences must be an array of non-negative integers", code: "MALFORMED_RESPONSE")
        end
        key = [candidate["start_ms"], candidate["end_ms"]]
        if boundaries.key?(key) || sequences.key?(candidate["sequence"])
          raise ContractError.new("candidate sequences and boundaries must be unique", code: "DUPLICATE_CANDIDATE")
        end
        boundaries[key] = true
        sequences[candidate["sequence"]] = true
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
