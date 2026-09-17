require "test_helper"

class LinkedinIntegrationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    @user = User.create!(email: "linkedin-integration-#{SecureRandom.hex(3)}@example.com", password: "password-123")
  end

  test "starts OAuth with state and no client secret in the URL" do
    login_as(@user)
    with_env(
      "LINKEDIN_CLIENT_ID", "client-id",
      "LINKEDIN_CLIENT_SECRET", "client-secret",
      "LINKEDIN_REDIRECT_URI", "https://cliprank.test/integrations/linkedin/callback"
    ) { get linkedin_connect_path }

    assert_response :redirect
    assert_includes response.location, "www.linkedin.com/oauth/v2/authorization"
    assert_includes response.location, "state="
    assert_not_includes response.location, "client-secret"
  end

  test "connects after a valid callback and queues a scoped sync" do
    login_as(@user)
    with_env(
      "LINKEDIN_CLIENT_ID", "client-id",
      "LINKEDIN_CLIENT_SECRET", "client-secret",
      "LINKEDIN_REDIRECT_URI", "https://cliprank.test/integrations/linkedin/callback"
    ) do
      get linkedin_connect_path
      state = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("state")
      fake = Object.new
      fake.define_singleton_method(:exchange_code) { |code:| { "access_token" => "token-#{code}", "expires_in" => 3600 } }
      fake.define_singleton_method(:profile) { |access_token:| { "sub" => "member-1", "name" => "Ada Lovelace" } }
      original_factory = IntegrationsController.linkedin_client_factory
      IntegrationsController.linkedin_client_factory = -> { fake }
      begin
        assert_enqueued_with(job: LinkedinSyncJob) do
          get linkedin_callback_path, params: { code: "authorization-code", state: state }
        end
      ensure
        IntegrationsController.linkedin_client_factory = original_factory
      end
    end

    assert_redirected_to integrations_path
    account = @user.linkedin_accounts.find_by!(linkedin_member_id: "member-1")
    assert_equal "Ada Lovelace", account.display_name
    assert_equal "token-authorization-code", account.access_token
  end

  test "rejects mismatched state and protects other users accounts" do
    login_as(@user)
    get linkedin_callback_path, params: { code: "authorization-code", state: "wrong" }
    assert_redirected_to integrations_path
    assert_empty @user.linkedin_accounts

    other = User.create!(email: "linkedin-other-#{SecureRandom.hex(3)}@example.com", password: "password-123")
    account = other.linkedin_accounts.create!(linkedin_member_id: "member-2", display_name: "Other", access_token: "private")
    post linkedin_sync_path(account)
    assert_response :not_found
    delete linkedin_disconnect_path(account)
    assert_response :not_found
    assert LinkedinAccount.exists?(account.id)
  end

  test "shows imported LinkedIn history and analytics" do
    account = @user.linkedin_accounts.create!(linkedin_member_id: "member-1", display_name: "Ada", access_token: "private")
    post = account.linkedin_posts.create!(
      linkedin_post_urn: "urn:li:share:123", commentary: "A useful LinkedIn lesson",
      content_type: "video", published_at: Time.zone.parse("2026-09-16 12:00:00 UTC")
    )
    post.linkedin_insight_snapshots.create!(
      linkedin_account: account, captured_on: Date.new(2026, 9, 17), captured_at: Time.zone.parse("2026-09-17 12:00:00 UTC"),
      metrics: { "impression" => 2_400, "reaction" => 80 }
    )
    login_as(@user)

    get integrations_path

    assert_response :success
    assert_select "[data-testid=linkedin-post-count]", text: "1"
    assert_select "[data-testid=linkedin-impression-count]", text: "2,400"
    assert_select "td", text: /A useful LinkedIn lesson/
  end

  private

  def login_as(user)
    post login_path, params: { session: { email: user.email, password: "password-123" } }
    assert_redirected_to videos_path
  end

  def with_env(*pairs)
    originals = pairs.each_slice(2).to_h { |key, value| [ key, ENV[key] ] }
    pairs.each_slice(2) { |key, value| ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
