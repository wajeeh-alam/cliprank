require "test_helper"
require "json"

class LinkedinClientTest < ActiveSupport::TestCase
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

  test "builds an authorization URL with state and analytics scopes" do
    client = Linkedin::Client.new(client_id: "client-id", client_secret: "client-secret", http_class: FakeHttp)
    url = client.authorization_url(state: "csrf-state", redirect_uri: "https://cliprank.test/integrations/linkedin/callback")
    query = URI.decode_www_form(URI.parse(url).query).to_h

    assert_equal "www.linkedin.com", URI.parse(url).host
    assert_equal "csrf-state", query.fetch("state")
    assert_equal %w[openid profile r_member_social r_member_postAnalytics], query.fetch("scope").split
    assert_not_includes url, "client-secret"
  end

  test "exchanges a code in a form body and retrieves the OIDC profile with bearer auth" do
    FakeHttp.responses = [
      Response.new("200", JSON.generate(access_token: "private-token", expires_in: 3600)),
      Response.new("200", JSON.generate(sub: "member-1", name: "Ada Lovelace"))
    ]
    client = Linkedin::Client.new(client_id: "client-id", client_secret: "client-secret", http_class: FakeHttp)

    token = client.exchange_code(code: "one-time-code", redirect_uri: "https://cliprank.test/callback")
    profile = client.profile(access_token: token.fetch("access_token"))

    assert_includes FakeHttp.requests.first.body, "code=one-time-code"
    assert_not_includes FakeHttp.requests.first.path, "one-time-code"
    assert_equal "Bearer private-token", FakeHttp.requests.second["Authorization"]
    assert_equal "/v2/userinfo", FakeHttp.requests.second.path
    assert_equal "member-1", profile.fetch("sub")
  end

  test "fetches a bounded page of posts using required version headers" do
    posts = 25.times.map { |index| { id: "urn:li:share:#{index}" } }
    FakeHttp.responses = [
      Response.new("200", JSON.generate(elements: posts)),
      Response.new("200", JSON.generate(elements: [ { id: "urn:li:share:last" } ]))
    ]
    client = Linkedin::Client.new(client_id: "id", client_secret: "secret", api_version: "202608", http_class: FakeHttp)

    result = client.posts(access_token: "private-token", linkedin_member_id: "member-1")

    assert_equal 26, result.length
    assert_equal 2, FakeHttp.requests.length
    assert_equal [ "0", "25" ], FakeHttp.requests.map { |request| URI.decode_www_form(URI.parse(request.path).query).to_h.fetch("start") }
    assert_equal [ "202608" ], FakeHttp.requests.map { |request| request["LinkedIn-Version"] }.uniq
    assert_equal [ "Bearer private-token" ], FakeHttp.requests.map { |request| request["Authorization"] }.uniq
    assert FakeHttp.requests.none? { |request| request.path.include?("private-token") }
  end

  test "rejects a non-LinkedIn API endpoint before sending a token" do
    error = assert_raises(Linkedin::Client::ConfigurationError) do
      Linkedin::Client.new(client_id: "id", client_secret: "secret", api_base_url: "https://attacker.example", http_class: FakeHttp)
    end

    assert_equal "LinkedIn API configuration is not allowed", error.message
    assert_empty FakeHttp.requests
  end
end
