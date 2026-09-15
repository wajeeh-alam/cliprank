require "test_helper"

class TranscriptSegmentTest < ActiveSupport::TestCase
  test "requires a positive timestamp interval" do
    segment = create_video.transcript_segments.build(
      sequence: 0,
      start_ms: 4_000,
      end_ms: 4_000,
      text: "No duration",
      transcript_version: "transcript-test"
    )

    assert_not segment.valid?
    assert_includes segment.errors[:end_ms], "must be greater than start_ms"
  end

  test "validates word timestamp schema" do
    segment = create_video.transcript_segments.build(
      sequence: 0,
      start_ms: 0,
      end_ms: 4_000,
      text: "Hello world",
      words: [ { "start_ms" => 2_000, "end_ms" => 1_000, "text" => "Hello" } ],
      transcript_version: "transcript-test"
    )

    assert_not segment.valid?
    assert segment.errors[:words].any?
  end
end
