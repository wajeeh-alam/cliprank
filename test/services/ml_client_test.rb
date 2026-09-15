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

  test "posts candidate feature requests and validates normalized feature families" do
    request_id = "req-features"
    idempotency_key = "video/1/run/2/features/candidate/3"
    data = feature_data
    FakeHttp.response = Response.new(
      "200",
      JSON.generate(
        contract_version: "1.0",
        request_id: request_id,
        idempotency_key: idempotency_key,
        data: data
      )
    )

    result = Ml::Client.new(base_url: "http://ml.test", service_token: "secret", http_class: FakeHttp).extract_features(
      { "video_id" => "1", "candidate_id" => "3", "feature_version" => "features-1" },
      request_id: request_id,
      idempotency_key: idempotency_key
    )

    assert_equal "baseline-1", result.fetch("model_version")
    assert_equal "/internal/api/v1/candidates/features", FakeHttp.requests.first.path
  end

  test "wraps a non-object HTTP error response without raising a type error" do
    FakeHttp.response = Response.new("502", JSON.generate([ "upstream failure" ]))

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

  private

  def feature_data
    {
      "video_id" => "1",
      "candidate_id" => "3",
      "feature_version" => "features-1",
      "model_version" => "baseline-1",
      "prompt_version" => nil,
      "semantic" => {
        "hook_strength" => 0.88, "standalone_clarity" => 0.96, "information_density" => 0.91,
        "novelty" => 0.67, "emotional_intensity" => 0.52, "quotability" => 0.84,
        "payoff_strength" => 0.90, "story_completeness" => 0.89, "technical_depth" => 0.61,
        "call_to_action_presence" => 0.10, "topic" => "career", "content_type" => "career_advice",
        "hook_type" => "contrarian"
      },
      "audio" => {
        "words_per_minute" => 168.2, "average_audio_energy" => 0.62, "energy_variance" => 0.18,
        "energy_change_at_hook" => 0.21, "silence_ratio" => 0.03, "longest_pause_ms" => 820,
        "pause_frequency" => 0.07
      },
      "visual" => {
        "face_presence_ratio" => 0.80, "visual_motion" => 0.31, "scene_change_rate" => 0.04,
        "screen_recording_ratio" => 0.0, "camera_change_frequency" => 0.02, "sample_count" => 20
      },
      "structural" => {
        "time_to_main_point_ms" => 1400, "intro_length_ms" => 1200, "sentence_completeness" => 0.94,
        "hook_to_payoff_time_ms" => 22_400, "dead_air_start_ms" => 0, "dead_air_end_ms" => 2100
      },
      "capability_warnings" => []
    }
  end
end
