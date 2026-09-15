require "test_helper"
require "json"

class MlClientTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body)

  class FakeHttp
    class << self
      attr_accessor :response, :requests
    end

    def initialize(host, port)
      @host = host
      @port = port
    end

    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout

    def start
      yield self
    end

    def request(request)
      self.class.requests << request
      self.class.response
    end
  end

  def setup
    FakeHttp.requests = []
  end

  test "sends service authentication and correlation headers and validates a transcription" do
    request_id = "req-123"
    idempotency_key = "video/1/run/2/transcription"
    FakeHttp.response = Response.new(
      "200",
      JSON.generate(
        contract_version: "1.0",
        request_id: request_id,
        idempotency_key: idempotency_key,
        data: {
          video_id: "1",
          transcript_version: "whisper-1",
          language: "en",
          segments: [
            {
              sequence: 0,
              start_ms: 0,
              end_ms: 20_000,
              text: "A complete thought.",
              words: [],
              is_sentence_boundary_start: true,
              is_sentence_boundary_end: true
            }
          ]
        }
      )
    )

    data = Ml::Client.new(base_url: "http://ml.test", service_token: "secret", http_class: FakeHttp).transcribe(
      { "video_id" => "1", "transcript_version" => "whisper-1" },
      request_id: request_id,
      idempotency_key: idempotency_key
    )

    request = FakeHttp.requests.fetch(0)
    assert_equal "Bearer secret", request["Authorization"]
    assert_equal request_id, request["X-Request-Id"]
    assert_equal idempotency_key, request["Idempotency-Key"]
    assert_equal "1", data.fetch("video_id")
  end

  test "rejects a response with a mismatched request id" do
    FakeHttp.response = Response.new(
      "200",
      JSON.generate(contract_version: "1.0", request_id: "wrong", idempotency_key: "idem", data: {})
    )

    error = assert_raises(Ml::Client::ContractError) do
      Ml::Client.new(base_url: "http://ml.test", service_token: "secret", http_class: FakeHttp).generate_candidates(
        { "video_id" => "1", "generation_version" => "candidate-1" },
        request_id: "req",
        idempotency_key: "idem"
      )
    end
    assert_equal "REQUEST_ID_MISMATCH", error.code
  end

  test "classifies 429 as retryable and 400 as permanent" do
    [ [ "429", true ], [ "400", false ] ].each do |status, retryable|
      FakeHttp.response = Response.new(
        status,
        JSON.generate(
          contract_version: "1.0",
          request_id: "req",
          idempotency_key: "idem",
          error: { code: "REMOTE_ERROR", message: "failure", retryable: retryable, details: {} }
        )
      )
      error = assert_raises(Ml::Client::HttpError) do
        Ml::Client.new(base_url: "http://ml.test", service_token: "secret", http_class: FakeHttp).generate_candidates(
          { "video_id" => "1", "generation_version" => "candidate-1" },
          request_id: "req",
          idempotency_key: "idem"
        )
      end
      assert_equal retryable, error.retryable?
    end
  end

  test "wraps a non-object HTTP error response without raising a type error" do
    FakeHttp.response = Response.new("502", JSON.generate(["upstream failure"]))

    error = assert_raises(Ml::Client::HttpError) do
      Ml::Client.new(base_url: "http://ml.test", service_token: "secret", http_class: FakeHttp).generate_candidates(
        { "video_id" => "1", "generation_version" => "candidate-1" },
        request_id: "req",
        idempotency_key: "idem"
      )
    end

    assert error.retryable?
    assert_nil error.request_id
  end
end
