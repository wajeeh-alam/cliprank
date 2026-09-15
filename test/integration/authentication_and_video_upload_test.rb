require "test_helper"
require "tempfile"

class AuthenticationAndVideoUploadTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(
      email: "creator@example.com", password: "password-123", password_confirmation: "password-123"
    )
    @other_user = User.create!(email: "other@example.com", password: "password-123")
    @tempfiles = []
  end

  teardown do
    @tempfiles.each(&:unlink)
  end

  test "requires authentication for the video workspace" do
    get videos_path

    assert_redirected_to login_path
    follow_redirect!
    assert_select "h1", "Welcome back"
  end

  test "registers, logs in, and logs out with a session cookie" do
    delete logout_path
    post signup_path, params: {
      user: {
        name: "New Creator",
        email: "new@example.com",
        password: "password-123",
        password_confirmation: "password-123"
      }
    }

    assert_redirected_to videos_path
    assert_equal "new@example.com", User.order(:created_at).last.email

    delete logout_path
    assert_redirected_to login_path

    post login_path, params: { session: { email: "new@example.com", password: "password-123" } }
    assert_redirected_to videos_path
  end

  test "rejects incorrect login credentials" do
    post login_path, params: { session: { email: @user.email, password: "wrong-password" } }

    assert_response :unprocessable_entity
    assert_select '[role="alert"]', /incorrect/
  end

  test "uploads accepted media, creates a processing run, and enqueues transcription" do
    login_as(@user)

    assert_enqueued_with(job: TranscribeVideoJob) do
      assert_difference [ "Video.count", "ProcessingRun.count" ], 1 do
        post videos_path, params: {
          video: { title: "Founder Q&A", source_media: uploaded_file("video/mp4", "founder.mp4") }
        }
      end
    end

    assert_redirected_to video_path(Video.last)
    video = Video.last
    assert video.source_media.attached?
    assert_equal "pending", video.processing_runs.last.status
  end

  test "requires an MP4 or MOV upload" do
    login_as(@user)

    assert_no_difference [ "Video.count", "ProcessingRun.count" ] do
      post videos_path, params: {
        video: { title: "Unsupported", source_media: uploaded_file("text/plain", "notes.txt") }
      }
    end

    assert_response :unprocessable_entity
    assert_select '[role="alert"]', /MP4 or MOV/
  end

  test "requires source media" do
    login_as(@user)

    assert_no_difference [ "Video.count", "ProcessingRun.count" ] do
      post videos_path, params: { video: { title: "Missing recording" } }
    end

    assert_response :unprocessable_entity
    assert_select '[role="alert"]', /source media.*selected/i
  end

  test "cannot view another user's video" do
    video = @other_user.videos.create!(title: "Private recording", pipeline_version: "phase1")
    login_as(@user)

    get video_path(video)

    assert_response :not_found
  end

  private

  def login_as(user)
    post login_path, params: { session: { email: user.email, password: "password-123" } }
    assert_redirected_to videos_path
  end

  def uploaded_file(content_type, filename)
    tempfile = Tempfile.new([ "clip-rank-upload", File.extname(filename) ])
    tempfile.binmode
    tempfile.write("test upload bytes")
    tempfile.rewind
    @tempfiles << tempfile
    Rack::Test::UploadedFile.new(tempfile.path, content_type, original_filename: filename)
  end
end
