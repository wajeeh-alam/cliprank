module Explanations
  class Generator
    VERSION = "deterministic-1".freeze
    MODEL_VERSION = "rails-rules-1".freeze

    FEATURE_GROUPS = {
      "semantic" => :semantic_features,
      "audio" => :audio_features,
      "visual" => :visual_features,
      "structural" => :structural_features
    }.freeze

    STRENGTH_THRESHOLDS = {
      [ "semantic_features", "hook_strength" ] => 0.7,
      [ "semantic_features", "standalone_clarity" ] => 0.7,
      [ "structural_features", "sentence_completeness" ] => 0.8,
      [ "audio_features", "average_audio_energy" ] => 0.6,
      [ "visual_features", "face_presence_ratio" ] => 0.6
    }.freeze

    WEAKNESS_THRESHOLDS = {
      [ "semantic_features", "hook_strength" ] => 0.45,
      [ "semantic_features", "standalone_clarity" ] => 0.55,
      [ "structural_features", "sentence_completeness" ] => 0.65,
      [ "audio_features", "silence_ratio" ] => 0.1,
      [ "visual_features", "visual_motion" ] => 0.15
    }.freeze

    SCORE_FACTS = %i[
      clip_score content_quality hook delivery pacing visual_engagement standalone_clarity
    ].freeze

    FEATURE_FACTS = [
      [ "Hook strength", "semantic_features", "hook_strength", "ratio" ],
      [ "Words per minute", "audio_features", "words_per_minute", "words/min" ],
      [ "Sentence completeness", "structural_features", "sentence_completeness", "ratio" ],
      [ "Longest pause", "audio_features", "longest_pause_ms", "milliseconds" ],
      [ "Visual motion", "visual_features", "visual_motion", "ratio" ]
    ].freeze

    class Error < StandardError; end

    def self.call(ranking_run)
      new(ranking_run).call
    end

    def initialize(ranking_run)
      @ranking_run = ranking_run
    end

    def call
      scores = @ranking_run.candidate_scores.order(:rank, :id).to_a
      raise Error, "A successful ranking run must have candidate scores" if scores.empty?

      scores.each do |score|
        raise Error, "A validated candidate score is required" unless score.valid?
        unless score.candidate_clip.video_id == @ranking_run.video_id
          raise Error, "A ranked candidate must belong to the ranking video"
        end

        feature_set = score.candidate_clip.candidate_feature_sets.find_by(feature_version: @ranking_run.feature_version)
        raise Error, "A validated feature set is required for every ranked candidate" unless feature_set&.valid?

        score.explanations.find_or_create_by!(explanation_version: VERSION) do |explanation|
          explanation.assign_attributes(build_payload(score, feature_set))
        end
      end
      scores
    end

    private

    def build_payload(score, feature_set)
      {
        explanation_version: VERSION,
        model_version: MODEL_VERSION,
        summary: summary_for(score, feature_set),
        strengths: strengths_for(score, feature_set),
        weaknesses: weaknesses_for(score, feature_set),
        quantitative_facts: quantitative_facts_for(score, feature_set)
      }
    end

    def summary_for(score, feature_set)
      topic = feature_value(feature_set, "semantic_features", "topic")
      "Ranked ##{score.rank} with a ClipScore of #{score.clip_score}. " \
        "The #{topic} candidate is supported by the persisted component and feature evidence below."
    end

    def strengths_for(score, feature_set)
      strengths = []
      STRENGTH_THRESHOLDS.each do |(group, key), threshold|
        next if visual_path?(group) && !visual_measurements_available?(feature_set)

        value = feature_value(feature_set, group, key)
        next unless value >= threshold

        label = key.humanize.downcase
        strengths << evidence(
          "#{label.capitalize} is a measured strength.",
          source_feature_path(group, key),
          value
        )
      end
      strengths << evidence("The ranked score is a measured strength.", "candidate_score.clip_score", score.clip_score) if strengths.empty? && score.clip_score >= 70
      strengths
    end

    def weaknesses_for(_score, feature_set)
      weaknesses = []
      WEAKNESS_THRESHOLDS.each do |(group, key), threshold|
        next if visual_path?(group) && !visual_measurements_available?(feature_set)

        value = feature_value(feature_set, group, key)
        is_weak = key == "silence_ratio" ? value >= threshold : value < threshold
        next unless is_weak

        label = key.humanize.downcase
        weaknesses << evidence(
          "#{label.capitalize} is a measured area for improvement.",
          source_feature_path(group, key),
          value
        )
      end
      weaknesses
    end

    def quantitative_facts_for(score, feature_set)
      score_facts = SCORE_FACTS.reject do |attribute|
        attribute == :visual_engagement && !visual_measurements_available?(feature_set)
      end.map do |attribute|
        {
          "metric" => attribute.to_s,
          "value" => score.public_send(attribute).to_f,
          "unit" => "score",
          "source_feature_path" => "candidate_score.#{attribute}"
        }
      end
      feature_facts = FEATURE_FACTS.reject do |_label, group, _key, _unit|
        visual_path?(group) && !visual_measurements_available?(feature_set)
      end.map do |label, group, key, unit|
        {
          "metric" => key,
          "value" => feature_value(feature_set, group, key),
          "unit" => unit,
          "source_feature_path" => source_feature_path(group, key)
        }
      end
      score_facts + feature_facts
    end

    def evidence(text, source_path, value)
      {
        "text" => text,
        "value" => value,
        "source_feature_path" => source_path
      }
    end

    def feature_value(feature_set, group, key)
      accessor = FEATURE_GROUPS.fetch(group.sub(/_features\z/, ""), group.to_sym)
      feature_set.public_send(accessor).fetch(key)
    rescue KeyError, NoMethodError
      raise Error, "Validated feature set is missing #{group}.#{key}"
    end

    def source_feature_path(group, key)
      "#{group}.#{key}"
    end

    def visual_path?(group)
      group == "visual_features"
    end

    def visual_measurements_available?(feature_set)
      warnings = Array(feature_set.raw_metadata["capability_warnings"])
      warnings.none? { |warning| warning == "NO_VIDEO_STREAM" || warning.is_a?(String) && warning.start_with?("VISUAL_") }
    end
  end
end
