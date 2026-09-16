require "test_helper"
require "json"

class InstagramClientTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body)

  class FakeHttp
    class << self
      attr_accessor :responses, :requests
    end

    def initialize(*); end
    attr_accessor :use_ssl, :open_timeout, :read_timeout

    def start
      yield self
    end

    def request(request)
      self.class.requests << request
      self.class.responses.shift
    end
  end

  setup do
    FakeHttp.requests = []
  end

  test "builds the Instagram Login authorization URL with the exact scopes" do
    url = Instagram::Client.new(app_id: "app-id", app_secret: "app-secret", http_class: FakeHttp)
      .authorization_url(state: "csrf-state", redirect_uri: "https://cliprank.test/integrations/instagram/callback")
    uri = URI.parse(url)

    assert_equal "www.instagram.com", uri.host
    query = URI.decode_www_form(uri.query).to_h
    assert_equal "instagram_business_basic,instagram_business_manage_insights", query.fetch("scope")
    assert_equal "csrf-state", query.fetch("state")
  end

  test "exchanges and refreshes tokens without putting secrets in request URLs for code exchange" do
    FakeHttp.responses = [
      Response.new("200", JSON.generate(access_token: "short-lived", user_id: "1")),
      Response.new("200", JSON.generate(access_token: "long-lived", expires_in: 5_000)),
      Response.new("200", JSON.generate(access_token: "refreshed", expires_in: 5_000))
    ]
    client = Instagram::Client.new(app_id: "app-id", app_secret: "app-secret", api_version: nil, http_class: FakeHttp)

    client.exchange_code(code: "authorization-code", redirect_uri: "https://cliprank.test/callback")
    client.exchange_long_lived_token(access_token: "short-lived")
    client.refresh_access_token(access_token: "long-lived")

    assert_equal "/oauth/access_token", FakeHttp.requests[0].path
    assert_includes FakeHttp.requests[0].body, "code=authorization-code"
    assert_equal "/access_token", URI.parse(FakeHttp.requests[1].path).path
    assert_includes FakeHttp.requests[1].path, "access_token=short-lived"
    assert_equal "/refresh_access_token", URI.parse(FakeHttp.requests[2].path).path
  end

  test "uses bearer authentication and cursor pagination for owned media" do
    FakeHttp.responses = [
      Response.new("200", JSON.generate(data: [ { id: "one" } ], paging: { cursors: { after: "next-cursor" } })),
      Response.new("200", JSON.generate(data: [ { id: "two" } ]))
    ]
    client = Instagram::Client.new(app_id: "app-id", app_secret: "app-secret", http_class: FakeHttp)

    media = client.media(access_token: "private-token", instagram_user_id: "account-1")

    assert_equal %w[one two], media.pluck("id")
    assert_equal [ "Bearer private-token", "Bearer private-token" ], FakeHttp.requests.map { |request| request["Authorization"] }
    assert_not_includes FakeHttp.requests.first.path, "private-token"
    assert_includes FakeHttp.requests.second.path, "after=next-cursor"
  end

  test "rejects a non-Meta graph endpoint before sending a bearer token" do
    error = assert_raises(Instagram::Client::ConfigurationError) do
      Instagram::Client.new(
        app_id: "app-id", app_secret: "app-secret",
        graph_base_url: "https://attacker.example", http_class: FakeHttp
      )
    end

    assert_equal "Instagram graph endpoint is not allowed", error.message
    assert_empty FakeHttp.requests
  end
end
