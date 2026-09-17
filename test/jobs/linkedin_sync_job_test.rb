require "test_helper"

class LinkedinSyncJobTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :post_calls, :analytics_calls

    def initialize
      @post_calls = []
      @analytics_calls = []
    end

    def posts(access_token:, linkedin_member_id:)
      @post_calls << [ access_token, linkedin_member_id ]
      [ {
        "id" => "urn:li:share:123", "commentary" => "A practical lesson",
        "publishedAt" => 1_789_473_600_000, "visibility" => "PUBLIC",
        "content" => { "media" => { "id" => "urn:li:video:one" } }
      } ]
    end

    def analytics(access_token:, linkedin_post_urn:)
      @analytics_calls << [ access_token, linkedin_post_urn ]
      { "impression" => 900, "reaction" => 40, "comment" => 5 }
    end
  end

  test "sync is idempotent and snapshots analytics without passing a token to the job" do
    user = User.create!(email: "linkedin-sync-#{SecureRandom.hex(3)}@example.com", password: "password-123")
    account = user.linkedin_accounts.create!(linkedin_member_id: "member-1", display_name: "Ada", access_token: "secret-token")
    client = FakeClient.new
    now = Time.zone.parse("2026-09-17 12:00:00 UTC")

    2.times { LinkedinSyncJob.perform_now(account.id, client: client, now: now) }

    assert_equal 1, account.linkedin_posts.count
    assert_equal 1, account.linkedin_insight_snapshots.count
    assert_equal "secret-token", client.post_calls.first.first
    assert_equal [ account.id ], LinkedinSyncJob.perform_later(account.id).arguments
    assert_equal 900, account.linkedin_insight_snapshots.first.metrics.fetch("impression")
  end

  test "rejects malformed provider posts without partially persisting them" do
    user = User.create!(email: "linkedin-bad-sync-#{SecureRandom.hex(3)}@example.com", password: "password-123")
    account = user.linkedin_accounts.create!(linkedin_member_id: "member-2", display_name: "Grace", access_token: "secret-token")
    client = FakeClient.new
    client.define_singleton_method(:posts) { |**| [ { "id" => "not-a-linkedin-urn" } ] }

    LinkedinSyncJob.perform_now(account.id, client: client)

    assert_empty account.linkedin_posts
    assert_equal "LinkedIn returned invalid post data", account.reload.sync_error
  end
end
