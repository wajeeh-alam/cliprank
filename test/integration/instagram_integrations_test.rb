require "test_helper"

class InstagramIntegrationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    @user = User.create!(email: "integration-#{SecureRandom.hex(3)}@example.com", password: "password-123")
  end

  test "requires authentication" do
    get integrations_path

    assert_redirected_to login_path
  end

  test "shows the authenticated integrations page" do
    login_as(@user)

    get integrations_path

    assert_response :success
    assert_select "h1", "Integrations"
    assert_select "a", text: "Connect Instagram"
  end

  test "starts OAuth with configured credentials and a state parameter" do
    login_as(@user)
    with_env(
      "META_INSTAGRAM_CLIENT_ID", "app-id",
      "META_INSTAGRAM_CLIENT_SECRET", "app-secret",
      "META_INSTAGRAM_REDIRECT_URI", "https://cliprank.test/integrations/instagram/callback"
    ) do
      get instagram_connect_path
    end

    assert_response :redirect
    location = response.headers.fetch("Location")
    assert_includes location, "www.instagram.com/oauth/authorize"
    assert_includes location, "state="
    assert_includes location, "instagram_business_basic"
    assert_includes location, "instagram_business_manage_insights"
    assert_not_includes location, "app-secret"
  end

  test "shows imported creator content and available analytics" do
    account = @user.instagram_accounts.create!(
      instagram_user_id: "17841400000000200", username: "creator", account_type: "CREATOR",
      access_token: "secret-token", last_synced_at: Time.zone.parse("2026-09-16 12:00:00 UTC")
    )
    media = account.instagram_media.create!(
      instagram_media_id: "media-dashboard-1", media_type: "VIDEO", media_product_type: "REELS",
      caption: "A useful short-form lesson", published_at: Time.zone.parse("2026-09-15 12:00:00 UTC"),
      like_count: 120, comments_count: 8, permalink: "https://instagram.com/p/dashboard"
    )
    media.instagram_insight_snapshots.create!(
      instagram_account: account, captured_at: Time.zone.parse("2026-09-16 12:00:00 UTC"),
      captured_on: Date.new(2026, 9, 16), metrics: { "views" => 2_400, "reach" => 1_900 }
    )
    login_as(@user)

    get integrations_path

    assert_response :success
    assert_select "[data-testid=instagram-media-count]", text: "1"
    assert_select "[data-testid=instagram-engagement-count]", text: "128"
    assert_select "[data-testid=instagram-views-count]", text: "2,400"
    assert_select "td", text: /A useful short-form lesson/
    assert_select "a[href='https://instagram.com/p/dashboard']", text: "Open post"
  end

  test "queues sync and disconnects only the current user's account" do
    account = @user.instagram_accounts.create!(
      instagram_user_id: "17841400000000000", username: "creator", account_type: "CREATOR",
      access_token: "secret-token"
    )
    login_as(@user)

    assert_enqueued_with(job: InstagramSyncJob, args: [ account.id ]) do
      post instagram_sync_path(account)
    end
    assert_redirected_to integrations_path

    assert_difference "InstagramAccount.count", -1 do
      delete instagram_disconnect_path(account)
    end
    assert_redirected_to integrations_path
  end

  test "rejects a callback whose OAuth state does not match" do
    login_as(@user)

    get instagram_callback_path, params: { code: "authorization-code", state: "wrong-state" }

    assert_redirected_to integrations_path
    follow_redirect!
    assert_select "div[role=alert]", text: /authorization expired/
    assert_empty @user.instagram_accounts
  end

  test "connects a Professional account after a valid callback" do
    login_as(@user)
    callback_url = "https://cliprank.test/integrations/instagram/callback"
    with_env(
      "META_INSTAGRAM_CLIENT_ID", "app-id",
      "META_INSTAGRAM_CLIENT_SECRET", "app-secret",
      "META_INSTAGRAM_REDIRECT_URI", callback_url
    ) do
      get instagram_connect_path
      state = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("state")
      fake = Object.new
      fake.define_singleton_method(:exchange_code) { |code:| { "access_token" => "short-#{code}" } }
      fake.define_singleton_method(:exchange_long_lived_token) { |access_token:| { "access_token" => "long-#{access_token}", "expires_in" => 3600 } }
      fake.define_singleton_method(:profile) do |access_token:|
        raise "unexpected token" unless access_token == "long-short-authorization-code"

        { "user_id" => "17841400000000099", "username" => "creator", "account_type" => "CREATOR" }
      end

      original_factory = IntegrationsController.instagram_client_factory
      IntegrationsController.instagram_client_factory = -> { fake }
      begin
        assert_enqueued_with(job: InstagramSyncJob) do
          get instagram_callback_path, params: { code: "authorization-code", state: state }
        end
      ensure
        IntegrationsController.instagram_client_factory = original_factory
      end
    end

    assert_redirected_to integrations_path
    account = @user.instagram_accounts.find_by!(instagram_user_id: "17841400000000099")
    assert_equal "long-short-authorization-code", account.access_token
  end

  test "cannot sync or disconnect another user's Instagram account" do
    other = User.create!(email: "other-#{SecureRandom.hex(3)}@example.com", password: "password-123")
    account = other.instagram_accounts.create!(
      instagram_user_id: "17841400000000100", username: "other", account_type: "CREATOR",
      access_token: "secret-token"
    )
    login_as(@user)

    post instagram_sync_path(account)
    assert_response :not_found
    delete instagram_disconnect_path(account)
    assert_response :not_found
    assert InstagramAccount.exists?(account.id)
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
