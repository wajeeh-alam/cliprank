require "json"
require "net/http"
require "uri"

module Linkedin
  class Client
    AUTHORIZATION_URL = "https://www.linkedin.com/oauth/v2/authorization".freeze
    TOKEN_URL = "https://www.linkedin.com/oauth/v2/accessToken".freeze
    API_URL = "https://api.linkedin.com".freeze
    DEFAULT_API_VERSION = "202608".freeze
    SCOPES = %w[openid profile r_member_social r_member_postAnalytics].freeze
    MAX_POSTS = 50
    PAGE_SIZE = 25
    MAX_POST_PAGES = 2
    ANALYTIC_METRICS = %w[IMPRESSION MEMBERS_REACHED RESHARE REACTION COMMENT POST_SAVE].freeze

    class Error < StandardError
      attr_reader :status, :code

      def initialize(message, status: nil, code: nil)
        super(message)
        @status = status
        @code = code
      end
    end

    class ConfigurationError < Error; end
    class RequestError < Error; end
    class RetryableError < RequestError; end
    class UnsupportedAnalyticsError < RequestError; end

    def initialize(client_id: ENV["LINKEDIN_CLIENT_ID"], client_secret: ENV["LINKEDIN_CLIENT_SECRET"],
                   api_base_url: ENV.fetch("LINKEDIN_API_BASE_URL", API_URL),
                   api_version: ENV.fetch("LINKEDIN_API_VERSION", DEFAULT_API_VERSION),
                   scopes: ENV.fetch("LINKEDIN_SCOPES", SCOPES.join(" ")).split,
                   http_class: Net::HTTP, open_timeout: 5, read_timeout: 30)
      @client_id = client_id.to_s
      @client_secret = client_secret.to_s
      @api_base_url = api_base_url.to_s.delete_suffix("/")
      @api_version = api_version.to_s
      @scopes = scopes
      @http_class = http_class
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      validate_configuration_values!
    end

    def authorization_url(state:, redirect_uri: ENV["LINKEDIN_REDIRECT_URI"])
      ensure_oauth_configuration!(redirect_uri)
      query = URI.encode_www_form(
        response_type: "code",
        client_id: @client_id,
        redirect_uri: redirect_uri,
        state: state,
        scope: @scopes.join(" ")
      )
      "#{AUTHORIZATION_URL}?#{query}"
    end

    def exchange_code(code:, redirect_uri: ENV["LINKEDIN_REDIRECT_URI"])
      ensure_oauth_configuration!(redirect_uri)
      post_form(TOKEN_URL, {
        grant_type: "authorization_code",
        code: code,
        client_id: @client_id,
        client_secret: @client_secret,
        redirect_uri: redirect_uri
      }).tap { |payload| require_token!(payload) }
    end

    def profile(access_token:)
      payload = get("/v2/userinfo", {}, access_token: access_token, versioned: false)
      return payload if payload["sub"].to_s.present?

      raise RequestError, "LinkedIn profile response was invalid"
    end

    def posts(access_token:, linkedin_member_id:)
      all = []
      MAX_POST_PAGES.times do |page|
        payload = get("/rest/posts", {
          q: "author",
          author: "urn:li:person:#{linkedin_member_id}",
          viewContext: "AUTHOR",
          start: page * PAGE_SIZE,
          count: PAGE_SIZE,
          sortBy: "CREATED"
        }, access_token: access_token, headers: { "X-RestLi-Method" => "FINDER" })
        elements = payload["elements"]
        raise RequestError, "LinkedIn returned an invalid posts response" unless elements.is_a?(Array)

        all.concat(elements.first(MAX_POSTS - all.length))
        break if elements.length < PAGE_SIZE || all.length >= MAX_POSTS
      end
      all
    end

    def analytics(access_token:, linkedin_post_urn:)
      entity = analytics_entity(linkedin_post_urn)
      ANALYTIC_METRICS.each_with_object({}) do |metric, result|
        payload = get("/rest/memberCreatorPostAnalytics", {
          q: "entity", entity: entity, queryType: metric, aggregation: "TOTAL"
        }, access_token: access_token)
        elements = payload["elements"]
        raise RequestError, "LinkedIn returned an invalid analytics response" unless elements.is_a?(Array)

        result[metric.downcase] = elements.first&.fetch("count", nil)
      end.compact
    rescue RequestError => error
      if [ 400, 403, 404 ].include?(error.status)
        raise UnsupportedAnalyticsError.new("LinkedIn analytics are unavailable", status: error.status, code: error.code)
      end

      raise
    end

    private

    def ensure_oauth_configuration!(redirect_uri)
      return if @client_id.present? && @client_secret.present? && redirect_uri.to_s.present?

      raise ConfigurationError, "LinkedIn integration is not configured"
    end

    def validate_configuration_values!
      uri = URI.parse(@api_base_url)
      valid_endpoint = uri.is_a?(URI::HTTPS) && uri.host == "api.linkedin.com" && uri.path.to_s.match?(%r{\A/?\z})
      valid_version = @api_version.match?(/\A20\d{4}\z/)
      raise ConfigurationError, "LinkedIn API configuration is not allowed" unless valid_endpoint && valid_version
    rescue URI::InvalidURIError
      raise ConfigurationError, "LinkedIn API configuration is not allowed"
    end

    def require_token!(payload)
      return if payload["access_token"].to_s.present?

      raise RequestError, "LinkedIn token response was invalid"
    end

    def analytics_entity(urn)
      value = urn.to_s
      return "(ugc:#{value})" if value.start_with?("urn:li:ugcPost:")
      return "(share:#{value})" if value.start_with?("urn:li:share:")

      raise RequestError, "LinkedIn post identifier was invalid"
    end

    def get(path, params, access_token:, headers: {}, versioned: true)
      uri = URI.join("#{@api_base_url}/", path.delete_prefix("/"))
      uri.query = URI.encode_www_form(params) if params.present?
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "ClipRank/LinkedIn"
      request["Authorization"] = "Bearer #{access_token}"
      request["LinkedIn-Version"] = @api_version if versioned
      request["X-Restli-Protocol-Version"] = "2.0.0" if versioned
      headers.each { |name, value| request[name] = value }
      execute(uri, request)
    end

    def post_form(url, params)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(params)
      execute(uri, request)
    end

    def execute(uri, request)
      http = @http_class.new(uri.host, uri.port)
      http.use_ssl = true if http.respond_to?(:use_ssl=)
      http.open_timeout = @open_timeout if http.respond_to?(:open_timeout=)
      http.read_timeout = @read_timeout if http.respond_to?(:read_timeout=)
      response = http.start { |connection| connection.request(request) }
      status = response.code.to_i
      payload = JSON.parse(response.body.to_s)
      raise RequestError.new("LinkedIn returned an invalid response", status: status) unless payload.is_a?(Hash)
      return payload if status.between?(200, 299)

      error_class = [ 408, 429 ].include?(status) || status >= 500 ? RetryableError : RequestError
      raise error_class.new("LinkedIn request failed", status: status, code: payload["code"] || payload["status"])
    rescue JSON::ParserError
      raise RequestError.new("LinkedIn returned invalid JSON", status: response&.code.to_i)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise RetryableError, "LinkedIn request timed out"
    rescue IOError, EOFError, SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      raise RetryableError, "LinkedIn request could not be completed"
    end
  end
end
