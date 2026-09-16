require "digest"

module TitleIdeas
  class Generator
    VERSION = "deterministic-1".freeze
    HISTORY_SAMPLE_MINIMUM = 5
    STOP_WORDS = %w[a about an and are as at be by for from how in is it of on or the this to was what when with your].freeze

    class Error < StandardError; end

    def self.call(ranking_run)
      new(ranking_run).call
    end

    def initialize(ranking_run)
      @ranking_run = ranking_run
    end

    def call
      raise Error, "A successful ranking run is required" unless @ranking_run.succeeded?

      creator_history = creator_history_snapshot
      scores = @ranking_run.candidate_scores.includes(candidate_clip: :candidate_feature_sets).order(:rank, :id).limit(5)
      raise Error, "A successful ranking run must have candidate scores" if scores.empty?

      scores.each do |score|
        feature_set = score.candidate_clip.candidate_feature_sets.find_by(feature_version: @ranking_run.feature_version)
        raise Error, "A feature set is required for every ranked candidate" unless feature_set

        history = relevant_history(score.candidate_clip, feature_set, creator_history)
        persist_set!(score, feature_set, history)
      end
    end

    private

    def persist_set!(score, feature_set, history)
      payload = set_payload(feature_set, history)
      titles = title_payloads(score.candidate_clip, feature_set, history)

      TitleIdeaSet.transaction do
        set = @ranking_run.title_idea_sets.find_or_initialize_by(
          candidate_clip: score.candidate_clip,
          version: VERSION
        )
        return set if set.persisted? && set.title_ideas.count == 3

        set.with_lock do
          set.update!(payload)
          set.title_ideas.delete_all
          titles.each_with_index do |title, index|
            set.title_ideas.create!(
              rank: index + 1,
              title: title.fetch(:title),
              angle: title.fetch(:angle),
              evidence: title.fetch(:evidence)
            )
          end
        end
      end
    end

    def set_payload(feature_set, history)
      {
        source_type: history[:source_type],
        sample_size: history[:sample_size],
        evidence: {
          "label" => history[:label],
          "sample_size" => history[:sample_size],
          "performance_basis" => history[:performance_basis],
          "caption_terms" => history[:terms],
          "history_fingerprint" => history[:fingerprint],
          "history_cutoff_at" => history[:cutoff_at],
          "source_media_ids" => history[:source_media_ids],
          "feature_version" => feature_set.feature_version
        }
      }
    end

    def title_payloads(candidate, feature_set, history)
      semantic = feature_set.semantic_features
      topic = clean_phrase(semantic["topic"], fallback: "this idea")
      excerpt = transcript_excerpt(candidate.transcript, fallback: topic)
      history_term = history[:terms].first
      candidates = if history[:source_type] == "instagram_history" && history_term.present?
        [
          [ "A practical #{history_term} take on #{topic}", "creator-history pattern" ],
          [ "The #{topic} angle in practice", "topic-led framing" ],
          [ "Your #{history_term} idea, reframed", "creator-history pattern" ]
        ]
      else
        transcript_titles(topic, excerpt, semantic["hook_type"])
      end

      titles = dedupe_titles(candidates.map do |title, angle|
        { title: normalize_length(title), angle: angle, evidence: title_evidence(feature_set, excerpt, history) }
      end)
      fallback_titles(topic, excerpt, history, feature_set).each do |candidate_title|
        break if titles.length >= 3

        titles << candidate_title unless similar_to_existing?(candidate_title.fetch(:title), titles)
      end
      raise Error, "Could not produce three distinct title ideas" unless titles.length == 3

      titles.first(3)
    end

    def transcript_titles(topic, excerpt, hook_type)
      hook_title = case hook_type.to_s
      when "question", "curiosity_gap"
        "A question about #{topic}"
      when "contrarian", "surprising_claim"
        "A different take on #{topic}"
      when "personal_story"
        "What I learned about #{topic}"
      when "result_first"
        "The idea behind #{topic}"
      else
        "A practical take on #{topic}"
      end

      [
        [ hook_title, "hook-led framing" ],
        [ "The idea behind #{excerpt}", "transcript hook" ],
        [ "Making sense of #{topic} in practice", "topic-led framing" ]
      ]
    end

    def fallback_titles(topic, excerpt, history, feature_set)
      evidence = title_evidence(feature_set, excerpt, history)
      [
        { title: normalize_length("A clear perspective on #{topic}"), angle: "topic-led framing", evidence: evidence },
        { title: normalize_length("What this says about #{topic}"), angle: "transcript framing", evidence: evidence },
        { title: normalize_length("One useful idea from #{excerpt}"), angle: "transcript hook", evidence: evidence }
      ]
    end

    def title_evidence(feature_set, excerpt, history)
      {
        "source_type" => history[:source_type],
        "creator_history_label" => history[:label],
        "sample_size" => history[:sample_size],
        "topic" => feature_set.semantic_features["topic"].to_s,
        "hook_type" => feature_set.semantic_features["hook_type"].to_s,
        "transcript_excerpt" => excerpt,
        "caption_terms" => history[:terms]
      }
    end

    def creator_history_snapshot
      media = InstagramMedia.joins(:instagram_account)
        .where(instagram_accounts: { user_id: @ranking_run.video.user_id })
        .where.not(caption: [ nil, "" ])
        .includes(:instagram_insight_snapshots)
        .order(:published_at, :id)
        .last(200)
      return transcript_history unless media.length >= HISTORY_SAMPLE_MINIMUM

      performance_scores = media.to_h { |item| [ item.id, performance_for(item) ] }
      ordered_performance = performance_scores.values.group_by { |score| score.fetch(:basis) }
        .transform_values { |scores| scores.map { |score| score.fetch(:value) }.sort }
      midpoint = [ (media.length / 2.0).ceil, 1 ].max
      older_media = media.first(media.length - midpoint)
      recent_media = media.last(midpoint)
      scored_terms = Hash.new(0.0)
      term_media_ids = Hash.new { |hash, key| hash[key] = [] }
      recent_media.each do |item|
        percentile = performance_percentile(performance_scores.fetch(item.id), ordered_performance)
        caption_tokens(item.caption).uniq.each do |term|
          scored_terms[term] += (1.0 / recent_media.length) + (percentile * 0.25)
          term_media_ids[term] << item.instagram_media_id
        end
      end
      older_media.each do |item|
        caption_tokens(item.caption).uniq.each { |term| scored_terms[term] -= 1.0 / older_media.length }
      end if older_media.any?
      terms = scored_terms.select { |_term, score| score.positive? }
        .sort_by { |term, score| [ -score, term ] }.first(12).map(&:first)
      return transcript_history if terms.empty?

      {
        source_type: "instagram_history",
        sample_size: media.length,
        terms: terms,
        term_media_ids: term_media_ids,
        performance_basis: performance_scores.values.any? { |score| score.fetch(:basis) == "engagement_rate" } ? "engagement_rate_with_likes_comments_fallback" : "likes_comments_fallback",
        label: "Based on rising creator history patterns across #{media.length} of your Instagram posts; not a global trends feed.",
        fingerprint: history_fingerprint(media, performance_scores),
        cutoff_at: media.filter_map(&:published_at).max&.iso8601
      }
    end

    def relevant_history(candidate, feature_set, history)
      return history unless history[:source_type] == "instagram_history"

      vocabulary = caption_tokens("#{feature_set.semantic_features['topic']} #{candidate.transcript}")
        .flat_map { |term| term_variants(term) }.uniq
      matched_terms = history[:terms].select { |term| (term_variants(term) & vocabulary).any? }.first(3)
      return transcript_history if matched_terms.empty?

      history.merge(
        terms: matched_terms,
        source_media_ids: matched_terms.flat_map { |term| history[:term_media_ids].fetch(term, []) }.uniq.first(10)
      )
    end

    def transcript_history
      {
        source_type: "transcript",
        sample_size: 0,
        terms: [],
        performance_basis: "not_available",
        label: "Based on this video's transcript and semantic features.",
        fingerprint: nil,
        cutoff_at: nil,
        source_media_ids: []
      }
    end

    def performance_for(media)
      snapshot = media.instagram_insight_snapshots.max_by { |item| [ item.captured_at, item.id ] }
      metrics = snapshot&.metrics || {}
      interactions = numeric(metrics["total_interactions"])
      interactions = %w[likes comments saved shares].sum { |key| numeric(metrics[key]) } unless interactions.positive?
      audience = %w[views plays reach impressions].map { |key| numeric(metrics[key]) }.max.to_f
      return { value: interactions / audience, basis: "engagement_rate" } if audience.positive?
      return { value: interactions, basis: "interaction_count_fallback" } if interactions.positive?

      {
        value: numeric(media.like_count) + numeric(media.comments_count),
        basis: "interaction_count_fallback"
      }
    end

    def performance_percentile(score, ordered_by_basis)
      ordered_values = ordered_by_basis.fetch(score.fetch(:basis))
      percentile = if ordered_values.length == 1
        1.0
      else
        index = ordered_values.bsearch_index { |item| item >= score.fetch(:value) } || (ordered_values.length - 1)
        index.to_f / (ordered_values.length - 1)
      end
      confidence = score.fetch(:basis) == "engagement_rate" ? 1.0 : 0.5
      percentile * confidence
    end

    def term_variants(term)
      variants = [ term ]
      if term.length > 5 && term.end_with?("ing")
        root = term.delete_suffix("ing")
        variants.concat([ root, "#{root}e" ])
      elsif term.length > 4 && term.end_with?("ed")
        root = term.delete_suffix("ed")
        variants.concat([ root, "#{root}e" ])
      elsif term.length > 4 && term.end_with?("s")
        variants << term.delete_suffix("s")
      end
      variants.uniq
    end

    def history_fingerprint(media, performance_scores)
      values = media.map do |item|
        score = performance_scores.fetch(item.id)
        [ item.instagram_media_id, item.caption, item.published_at&.iso8601, score.fetch(:basis), score.fetch(:value).round(8) ]
      end
      Digest::SHA256.hexdigest(values.to_json)
    end

    def caption_tokens(caption)
      caption.to_s.downcase.scan(/[\p{L}\p{N}][\p{L}\p{N}'-]*/u)
        .map { |token| token.delete_prefix("#") }
        .select { |token| token.length >= 3 && !STOP_WORDS.include?(token) }
    end

    def numeric(value)
      Float(value)
    rescue ArgumentError, TypeError
      0.0
    end

    def clean_phrase(value, fallback:)
      phrase = value.to_s.gsub(/[^\p{L}\p{N}\s'-]/u, " ").squish
      phrase.present? ? phrase : fallback
    end

    def transcript_excerpt(transcript, fallback:)
      phrase = clean_phrase(transcript, fallback: fallback)
      phrase.split.first(6).join(" ").presence || fallback
    end

    def normalize_length(title)
      words = title.to_s.split
      words = (words + %w[in practice]).first(12) while words.length < 4
      words.first(12).join(" ")
    end

    def dedupe_titles(candidates)
      candidates.each_with_object([]) do |candidate, result|
        result << candidate unless similar_to_existing?(candidate.fetch(:title), result)
      end
    end

    def similar_to_existing?(title, candidates)
      tokens = normalized_tokens(title)
      candidates.any? do |candidate|
        other = normalized_tokens(candidate.fetch(:title))
        union = (tokens | other).length
        union.positive? && ((tokens & other).length.to_f / union) >= 0.6
      end
    end

    def normalized_tokens(title)
      title.to_s.downcase.scan(/[\p{L}\p{N}]+/u).reject { |token| STOP_WORDS.include?(token) }
    end
  end
end
