module TitleIdeas
  class Enqueuer
    def self.call(ranking_run)
      new(ranking_run).call
    end

    def initialize(ranking_run)
      @ranking_run = ranking_run
      @claimed = false
    end

    def call
      @ranking_run.with_lock do
        current_version = @ranking_run.title_ideas_version == Generator::VERSION
        return false if current_version && %w[generating succeeded failed].include?(@ranking_run.title_ideas_status)

        @ranking_run.update!(
          title_ideas_status: "generating",
          title_ideas_version: Generator::VERSION,
          title_ideas_error: nil
        )
        @claimed = true
      end
      GenerateTitleIdeasJob.perform_later(@ranking_run.id)
      true
    rescue StandardError
      release_claim
      raise
    end

    private

    def release_claim
      return unless @claimed

      @ranking_run.with_lock do
        if @ranking_run.title_ideas_status == "generating" && @ranking_run.title_ideas_version == Generator::VERSION
          @ranking_run.update!(title_ideas_status: "pending", title_ideas_error: nil)
        end
      end
    end
  end
end
