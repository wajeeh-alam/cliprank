require "test_helper"

class InstagramSyncJobTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :media_calls, :insight_calls

    def initialize
      @media_calls = []
      @insight_calls = []
    end

    def media(access_token:, instagram_user_id:)
      @media_calls << [ access_token, instagram_user_id ]
      [ {
        "id" => "media-1", "media_type" => "VIDEO", "media_product_type" => "REELS",
        "caption" => "A post", "timestamp" => "2026-09-15T12:00:00+0000", "like_count" => 4,
        "comments_count" => 2, "permalink" => "https://instagram.com/p/one"
      } ]
    end

    def insights(access_token:, instagram_media_id:)
      @insight_calls << [ access_token, instagram_media_id ]
      { "reach" => 100, "likes" => 4 }
    end
  end

  test "sync is idempotent and never passes a token as a job argument" do
    user = User.create!(email: "sync-#{SecureRandom.hex(3)}@example.com", password: "password-123")
    account = user.instagram_accounts.create!(
      instagram_user_id: "17841400000000000", username: "creator", account_type: "BUSINESS",
      access_token: "secret-token"
    )
    fake = FakeClient.new
    now = Time.zone.parse("2026-09-15 12:00:00 UTC")

    2.times { InstagramSyncJob.perform_now(account.id, client: fake, now: now) }

    assert_equal 1, account.instagram_media.count
    assert_equal 1, account.instagram_insight_snapshots.count
    assert_equal "secret-token", fake.media_calls.first.first
    assert_equal [ account.id ], InstagramSyncJob.perform_later(account.id).arguments
  end

  test "rejects malformed provider media without partially persisting it" do
    user = User.create!(email: "bad-sync-#{SecureRandom.hex(3)}@example.com", password: "password-123")
    account = user.instagram_accounts.create!(
      instagram_user_id: "17841400000000001", username: "creator", account_type: "BUSINESS",
      access_token: "secret-token"
    )
    client = FakeClient.new
    client.define_singleton_method(:media) { |**| [ { "id" => "", "media_type" => "UNKNOWN" } ] }

    InstagramSyncJob.perform_now(account.id, client: client)

    assert_empty account.instagram_media
    assert_equal "Instagram returned invalid media data", account.reload.sync_error
  end
end
