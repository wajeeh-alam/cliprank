require "yaml"

module Pipeline
  class RankingConfig
    REQUIRED_WEIGHT_KEYS = %w[semantic hook structural delivery visual].freeze
    PATH = Rails.root.join("config", "ranking.yml").freeze

    class << self
      def for(feature_version: nil, scorer_version: nil)
        scorer_version ||= ENV.fetch("ML_SCORER_VERSION", "heuristic-1")
        versions = YAML.safe_load(File.read(PATH), aliases: false).fetch("versions")
        version = versions.fetch(scorer_version) do
          raise Ml::Client::ConfigurationError.new("Unknown ranking scorer version", code: "RANKING_CONFIG_MISSING",
            details: { "scorer_version" => scorer_version })
        end
        configured_feature_version = version.fetch("feature_version")
        if feature_version && feature_version.to_s != configured_feature_version.to_s
          raise Ml::Client::ConfigurationError.new("Ranking feature and scorer versions do not match", code: "RANKING_CONFIG_MISMATCH",
            details: { "feature_version" => feature_version, "configured_feature_version" => configured_feature_version })
        end

        config = {
          "feature_version" => configured_feature_version.to_s,
          "scorer_version" => scorer_version.to_s,
          "weights" => version.fetch("weights").transform_keys(&:to_s).transform_values(&:to_f),
          "output_scale" => Integer(version.fetch("output_scale"))
        }
        config["request_config"] = {
          "weights" => config.fetch("weights"),
          "output_scale" => config.fetch("output_scale")
        }
        validate!(config)
        deep_freeze(config)
      rescue Psych::SyntaxError => e
        raise Ml::Client::ConfigurationError.new("Ranking configuration is invalid", code: "RANKING_CONFIG_INVALID",
          details: { "reason" => e.message })
      rescue KeyError, TypeError, ArgumentError, NoMethodError => e
        raise Ml::Client::ConfigurationError.new("Ranking configuration is incomplete", code: "RANKING_CONFIG_INVALID",
          details: { "reason" => e.message })
      end

      private

      def validate!(config)
        weights = config.fetch("weights")
        unless weights.keys.sort == REQUIRED_WEIGHT_KEYS.sort && weights.values.all? { |value| value.between?(0.0, 1.0) } && (weights.values.sum - 1.0).abs <= 0.000001
          raise Ml::Client::ConfigurationError.new("Ranking weights must be normalized", code: "RANKING_CONFIG_INVALID")
        end
        raise Ml::Client::ConfigurationError.new("Ranking output scale must be 100", code: "RANKING_CONFIG_INVALID") unless config["output_scale"] == 100
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
