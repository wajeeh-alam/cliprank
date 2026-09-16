require "json"
require "net/http"
require "uri"

module Instagram
  class Client
    AUTHORIZATION_URL = "https://www.instagram.com/oauth/authorize".freeze
    TOKEN_URL = "https://api.instagram.com/oauth/access_token".freeze
    GRAPH_URL = "https://graph.instagram.com".freeze
    GRAPH_HOST = "graph.instagram.com".freeze
    MAX_MEDIA_ITEMS = 200
    MAX_MEDIA_PAGES = 2
    SCOPES = %w[instagram_business_basic].freeze
    MEDIA_FIELDS = %w[id caption media_type media_product_type permalink thumbnail_url timestamp like_count comments_count].freeze
    INSIGHT_METRICS = %w[impressions reach likes comments saved shares plays total_interactions].freeze

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
    class UnsupportedInsightsError < RequestError; end

    def initialize(app_id: ENV["META_INSTAGRAM_CLIENT_ID"], app_secret: ENV["META_INSTAGRAM_CLIENT_SECRET"],
                   graph_base_url: ENV.fetch("META_INSTAGRAM_GRAPH_BASE_URL", GRAPH_URL),
                   api_version: ENV["META_INSTAGRAM_API_VERSION"],
                   http_class: Net::HTTP, open_timeout: 5, read_timeout: 30)
      @app_id = app_id.to_s
      @app_secret = app_secret.to_s
      @graph_base_url = graph_base_url.to_s.delete_suffix("/")
      @api_version = api_version.to_s.delete_prefix("/").delete_suffix("/")
      @http_class = http_class
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      validate_graph_base_url!
    end

    def authorization_url(state:, redirect_uri: ENV["META_INSTAGRAM_REDIRECT_URI"])
      ensure_configuration!(redirect_uri)
      query = URI.encode_www_form(
        client_id: @app_id,
        redirect_uri: redirect_uri,
        response_type: "code",
        scope: SCOPES.join(","),
        state: state
      )
      "#{AUTHORIZATION_URL}?#{query}"
    end

    def exchange_code(code:, redirect_uri: ENV["META_INSTAGRAM_REDIRECT_URI"])
      ensure_configuration!(redirect_uri)
      post_form(TOKEN_URL, {
        client_id: @app_id,
        client_secret: @app_secret,
        grant_type: "authorization_code",
        redirect_uri: redirect_uri,
        code: code
      }).tap { |payload| require_token!(payload) }
    end
    alias exchange_code! exchange_code

    def exchange_long_lived_token(access_token:)
      get(@graph_base_url, versioned_path("access_token"), {
        grant_type: "ig_exchange_token",
        client_secret: @app_secret,
        access_token: access_token
      }).tap { |payload| require_token!(payload) }
    end
    alias exchange_long_lived_token! exchange_long_lived_token

    def refresh_access_token(access_token:)
      get(@graph_base_url, versioned_path("refresh_access_token"), {
        grant_type: "ig_refresh_token",
        access_token: access_token
      }).tap { |payload| require_token!(payload) }
    end
    alias refresh_access_token! refresh_access_token

    def profile(access_token:)
      get(@graph_base_url, versioned_path("me"), { fields: "user_id,username,account_type" }, access_token: access_token)
    end
    alias profile! profile

    def media(access_token:, instagram_user_id:)
      path = versioned_path("#{escape_path(instagram_user_id)}/media")
      all = []
      after = nil
      seen_cursors = {}
      MAX_MEDIA_PAGES.times do
        params = { fields: MEDIA_FIELDS.join(","), limit: 100 }
        params[:after] = after if after.present?
        payload = get(@graph_base_url, path, params, access_token: access_token)
        data = payload["data"]
        raise RequestError, "Instagram returned an invalid media response" unless data.is_a?(Array)

        all.concat(data.first(MAX_MEDIA_ITEMS - all.length))
        break if all.length >= MAX_MEDIA_ITEMS

        after = payload.dig("paging", "cursors", "after")
        break if after.blank? || seen_cursors[after]

        seen_cursors[after] = true
      end
      all
    end
    alias media! media

    def insights(access_token:, instagram_media_id:)
      payload = get(@graph_base_url, versioned_path("#{escape_path(instagram_media_id)}/insights"), {
        metric: INSIGHT_METRICS.join(",")
      }, access_token: access_token)
      data = payload["data"]
      raise RequestError, "Instagram returned an invalid insights response" unless data.is_a?(Array)

      data.each_with_object({}) do |metric, result|
        next unless metric.is_a?(Hash) && metric["name"].is_a?(String)

        values = metric["values"]
        value = values.is_a?(Array) ? values.last : nil
        value = value["value"] if value.is_a?(Hash)
        value = metric.dig("total_value", "value") if value.nil?
        result[metric["name"]] = value
      end
    rescue RequestError => e
      if [ 400, 403, 404 ].include?(e.status)
        raise UnsupportedInsightsError.new("Instagram insights are unavailable", status: e.status, code: e.code)
      end

      raise
    end
    alias insights! insights

    private

    def ensure_configuration!(redirect_uri)
      missing = []
      missing << "META_INSTAGRAM_CLIENT_ID" if @app_id.empty?
      missing << "META_INSTAGRAM_CLIENT_SECRET" if @app_secret.empty?
      missing << "META_INSTAGRAM_REDIRECT_URI" if redirect_uri.to_s.empty?
      raise ConfigurationError, "Instagram integration is not configured" if missing.any?
    end

    def validate_graph_base_url!
      uri = URI.parse(@graph_base_url)
      return if uri.is_a?(URI::HTTPS) && uri.host == GRAPH_HOST && uri.path.to_s.match?(%r{\A/?\z})

      raise ConfigurationError, "Instagram graph endpoint is not allowed"
    rescue URI::InvalidURIError
      raise ConfigurationError, "Instagram graph endpoint is not allowed"
    end

    def require_token!(payload)
      return if payload.is_a?(Hash) && payload["access_token"].is_a?(String) && payload["access_token"].present?

      raise RequestError, "Instagram token response was invalid"
    end

    def escape_path(value)
      URI::DEFAULT_PARSER.escape(value.to_s, /[^#{URI::PATTERN::UNRESERVED}]/)
    end

    def versioned_path(resource)
      [ "", @api_version.presence, resource.to_s.delete_prefix("/") ].compact.join("/")
    end

    def get(base, path, params, access_token: nil)
      uri = URI.parse(base)
      uri.path = path
      uri.query = URI.encode_www_form(params)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "ClipRank/Instagram"
      request["Authorization"] = "Bearer #{access_token}" if access_token.present?
      execute(uri, request)
    rescue URI::InvalidURIError
      raise RequestError, "Instagram returned an invalid pagination URL"
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
      http.use_ssl = uri.scheme == "https" if http.respond_to?(:use_ssl=)
      http.open_timeout = @open_timeout if http.respond_to?(:open_timeout=)
      http.read_timeout = @read_timeout if http.respond_to?(:read_timeout=)
      response = http.start { |connection| connection.request(request) }
      status = response.code.to_i
      payload = JSON.parse(response.body.to_s)
      unless payload.is_a?(Hash)
        raise RequestError.new("Instagram returned an invalid response", status: status)
      end
      return payload if status.between?(200, 299)

      error_class = [ 408, 429 ].include?(status) || status >= 500 ? RetryableError : RequestError
      raise error_class.new("Instagram request failed", status: status, code: payload.dig("error", "code"))
    rescue JSON::ParserError
      raise RequestError.new("Instagram returned invalid JSON", status: response&.code.to_i)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise RetryableError, "Instagram request timed out"
    rescue IOError, EOFError, SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      raise RetryableError, "Instagram request could not be completed"
    end
  end
end
