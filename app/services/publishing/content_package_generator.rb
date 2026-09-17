module Publishing
  class ContentPackageGenerator
    VERSION = "deterministic-1".freeze
    HISTORY_LIMIT = 50
    HISTORY_SAMPLE_MINIMUM = 5
    STOP_WORDS = %w[
      a about an and are as at be by for from how i in is it of on or that the this to was
      we what when with you your
    ].freeze

    class Error < StandardError; end

    def self.call(publishing_draft)
      new(publishing_draft).call
    end

    def initialize(publishing_draft)
      @draft = publishing_draft
    end

    def call
      raise Error, "Only editable drafts can generate content" unless @draft.status.in?(%w[draft ready_for_review])

      feature_set = @draft.candidate_clip.candidate_feature_sets.order(created_at: :desc, id: :desc).first
      semantic = feature_set&.semantic_features || {}
      brand = current_brand_profile
      history = creator_history
      context = build_context(semantic, brand, history)

      PublishingDraft.transaction do
        DraftVariant::PLATFORMS.each do |platform|
          variant = @draft.draft_variants.find_or_initialize_by(platform: platform)
          variant.assign_attributes(package_for(platform, context))
          variant.save!
        end
        @draft.update!(generator_version: VERSION, generated_at: Time.current, error_message: nil)
      end

      @draft.reload
    end

    private

    def build_context(semantic, brand, history)
      transcript = clean_text(@draft.candidate_clip.transcript)
      topic = clean_text(semantic["topic"]).presence || transcript.split.first(6).join(" ").presence || "your next idea"
      brand_values = brand_context(brand)
      history = relevant_history(history, "#{topic} #{transcript} #{Array(brand_values[:preferred_terms]).join(' ')}")
      preferred_term = Array(brand_values[:preferred_terms]).map { |term| clean_text(term) }
        .find { |term| term.present? && !avoided?(term, brand_values[:avoided_terms]) }

      {
        transcript: transcript,
        excerpt: sentence_excerpt(transcript, fallback: topic),
        topic: topic,
        content_type: semantic["content_type"].presence || "other",
        hook_type: semantic["hook_type"].presence || "none",
        brand: brand_values,
        brand_term: preferred_term,
        history: history
      }
    end

    def relevant_history(history, text)
      vocabulary = tokenized(text)
      terms = history[:terms].select { |term| vocabulary.include?(term) }
      return history.merge(terms: [], source_media_ids: []) if terms.empty?

      history.merge(
        terms: terms,
        source_media_ids: terms.flat_map { |term| history.fetch(:term_media_ids, {}).fetch(term, []) }.uniq.first(10)
      )
    end

    def package_for(platform, context)
      history_term = context.dig(:history, :terms)&.first
      framing_term = history_term.presence || context[:brand_term].presence
      title = title_for(platform, context, framing_term)
      description = description_for(platform, context, framing_term)
      hashtags = hashtags_for(platform, context)

      {
        title: filter_avoided(title, context.dig(:brand, :avoided_terms)).truncate(255),
        description: filter_avoided(description, context.dig(:brand, :avoided_terms)),
        hashtags: hashtags,
        cta: context.dig(:brand, :default_cta).presence || default_cta(platform),
        evidence: evidence_for(platform, context)
      }
    end

    def title_for(platform, context, framing_term)
      topic = context[:topic]
      prefix = case context[:hook_type]
      when "question", "curiosity_gap" then "A question about"
      when "contrarian", "surprising_claim" then "A different take on"
      when "personal_story" then "What I learned about"
      when "result_first" then "The result behind"
      else "A practical take on"
      end
      base = "#{prefix} #{topic}"
      return base unless framing_term.present?

      platform == "instagram" ? "#{base}: #{framing_term}" : "#{topic.titleize}: a #{framing_term} perspective"
    end

    def description_for(platform, context, framing_term)
      audience = context.dig(:brand, :audience).presence
      voice = context.dig(:brand, :voice).presence
      detail = [ context[:excerpt], ("A #{framing_term} angle." if framing_term.present?) ].compact.join(" ")

      if platform == "instagram"
        [ detail, ("For #{audience}." if audience), default_cta(platform) ].compact.join("\n\n")
      else
        lead = "#{context[:topic].titleize} is worth a closer look."
        notes = [ ("Written for #{audience}." if audience), ("Brand voice: #{voice}." if voice) ].compact.join(" ")
        [ lead, detail, notes.presence, default_cta(platform) ].compact.join("\n\n")
      end
    end

    def hashtags_for(platform, context)
      raw_terms = tokenized(context[:topic]) + context.dig(:history, :terms).to_a +
        Array(context.dig(:brand, :preferred_terms)) + [ context[:content_type] ]
      avoided = Array(context.dig(:brand, :avoided_terms)).flat_map { |term| tokenized(term) }
      limit = platform == "instagram" ? 8 : 5

      raw_terms.flat_map { |term| tokenized(term) }
        .reject { |term| avoided.include?(term) }
        .uniq.first(limit).map { |term| "##{term.delete(' _-')}" }
    end

    def evidence_for(platform, context)
      {
        "generator_version" => VERSION,
        "platform" => platform,
        "sources" => [
          "video_transcript",
          "semantic_features",
          ("brand_profile" if context.dig(:brand, :id)),
          ("instagram_history" if context.dig(:history, :sample_size).positive?)
        ].compact,
        "topic" => context[:topic],
        "content_type" => context[:content_type],
        "hook_type" => context[:hook_type],
        "transcript_excerpt" => context[:excerpt],
        "brand_profile_id" => context.dig(:brand, :id),
        "instagram_history" => {
          "sample_size" => context.dig(:history, :sample_size),
          "terms" => context.dig(:history, :terms),
          "source_media_ids" => context.dig(:history, :source_media_ids),
          "label" => context.dig(:history, :label)
        }
      }
    end

    def current_brand_profile
      model = "BrandProfile".safe_constantize
      return unless model

      model.find_by(user_id: @draft.user_id)
    end

    def brand_context(brand)
      return { preferred_terms: [], avoided_terms: [] } unless brand

      {
        id: brand.id,
        brand_name: brand_value(brand, :brand_name),
        audience: brand_value(brand, :audience),
        voice: brand_value(brand, :voice),
        preferred_terms: array_value(brand_value(brand, :preferred_terms)),
        avoided_terms: array_value(brand_value(brand, :avoided_terms)),
        default_cta: brand_value(brand, :default_cta)
      }
    end

    def brand_value(brand, name)
      brand.public_send(name) if brand.respond_to?(name)
    end

    def array_value(value)
      value.is_a?(Array) ? value : value.to_s.split(/[,\n]/).map(&:strip).reject(&:blank?)
    end

    def creator_history
      media = InstagramMedia.joins(:instagram_account)
        .where(instagram_accounts: { user_id: @draft.user_id })
        .where.not(caption: [ nil, "" ])
        .includes(:instagram_insight_snapshots)
        .order(published_at: :desc, id: :desc).limit(HISTORY_LIMIT).to_a
      if media.length < HISTORY_SAMPLE_MINIMUM
        return { sample_size: media.length, terms: [], source_media_ids: [], term_media_ids: {}, label: "Not enough past Instagram posts to infer creator-history patterns." }
      end

      weighted_terms = Hash.new(0.0)
      source_ids = Hash.new { |hash, key| hash[key] = [] }
      media.each_with_index do |item, index|
        recency = 1.0 - (index.to_f / [ media.length, 1 ].max)
        performance = performance_weight(item)
        tokenized(item.caption).uniq.each do |term|
          weighted_terms[term] += recency + performance
          source_ids[term] << item.instagram_media_id
        end
      end
      terms = weighted_terms.sort_by { |term, score| [ -score, term ] }.first(8).map(&:first)

      {
        sample_size: media.length,
        terms: terms,
        source_media_ids: terms.flat_map { |term| source_ids[term] }.uniq.first(10),
        term_media_ids: source_ids,
        label: "Based only on performance and language from #{media.length} past Instagram posts; not a prediction or global trends feed."
      }
    end

    def performance_weight(media)
      snapshot = media.instagram_insight_snapshots.max_by { |item| [ item.captured_at, item.id ] }
      metrics = snapshot&.metrics || {}
      interactions = numeric(metrics["total_interactions"])
      interactions = %w[likes comments saved shares].sum { |key| numeric(metrics[key]) } unless interactions.positive?
      interactions = numeric(media.like_count) + numeric(media.comments_count) unless interactions.positive?
      Math.log10(interactions + 1) / 10.0
    end

    def tokenized(text)
      text.to_s.downcase.scan(/[\p{L}\p{N}][\p{L}\p{N}'_-]*/u)
        .map { |token| token.delete_prefix("#") }
        .select { |token| token.length >= 3 && !STOP_WORDS.include?(token) }
    end

    def clean_text(value)
      value.to_s.gsub(/[^\p{L}\p{N}\s.,!?&'():_-]/u, " ").squish
    end

    def sentence_excerpt(transcript, fallback:)
      excerpt = transcript.split(/(?<=[.!?])\s+/).first.to_s.split.first(24).join(" ")
      excerpt.presence || fallback
    end

    def avoided?(text, avoided_terms)
      downcased = text.to_s.downcase
      Array(avoided_terms).any? { |term| term.present? && downcased.include?(term.to_s.downcase) }
    end

    def filter_avoided(text, avoided_terms)
      Array(avoided_terms).reduce(text.to_s) do |result, term|
        next result if term.blank?

        result.gsub(/#{Regexp.escape(term.to_s)}/i, "").squish
      end
    end

    def default_cta(platform)
      platform == "instagram" ? "Save this for later and share your take." : "What has worked in your experience?"
    end

    def numeric(value)
      Float(value)
    rescue ArgumentError, TypeError
      0.0
    end
  end
end
