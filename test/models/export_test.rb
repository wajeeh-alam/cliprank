require "test_helper"

class ExportTest < ActiveSupport::TestCase
  test "requires export boundaries to be ordered" do
    candidate = create_candidate
    export = candidate.exports.build(
      user: candidate.video.user,
      start_ms: 5_000,
      end_ms: 5_000,
      export_version: "export-test"
    )

    assert_not export.valid?
    assert_includes export.errors[:end_ms], "must be greater than start_ms"
  end

  test "attaches a rendered file and belongs to its owner and candidate" do
    candidate = create_candidate
    export = candidate.exports.create!(
      user: candidate.video.user,
      start_ms: 0,
      end_ms: 20_000,
      export_version: "export-test"
    )

    assert_equal "requested", export.status
    assert_respond_to export, :rendered_file
    assert_equal candidate.video.user, export.user
  end
end
