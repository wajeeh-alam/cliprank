class GenerateTitleIdeasJob < ApplicationJob
  queue_as :default
  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.send(:record_failure, job.arguments.first, error)
  end

  # Title generation is a presentation enhancement. A malformed imported
  # caption or feature row must never make an otherwise successful ranking
  # or preview pipeline fail.
  def perform(ranking_run_id, generator: nil)
    ranking_run = RankingRun.find(ranking_run_id)
    ranking_run.with_lock do
      return unless ranking_run.succeeded?
      return if current_version_succeeded?(ranking_run)

      ranking_run.update!(
        title_ideas_status: "generating",
        title_ideas_version: TitleIdeas::Generator::VERSION,
        title_ideas_error: nil
      )
      (generator || TitleIdeas::Generator).call(ranking_run)
      ranking_run.update!(
        title_ideas_status: "succeeded",
        title_ideas_version: TitleIdeas::Generator::VERSION,
        title_ideas_error: nil
      )
    end
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    raise
  rescue TitleIdeas::Generator::Error => e
    record_failure(ranking_run_id, e)
    Rails.logger.warn("Title ideas skipped for ranking run #{ranking_run_id}: #{e.class}: #{e.message}")
    nil
  rescue StandardError => e
    record_failure(ranking_run_id, e)
    Rails.logger.error("Title ideas failed for ranking run #{ranking_run_id}: #{e.class}: #{e.message}")
    nil
  end

  private

  def record_failure(ranking_run_id, error)
    ranking_run = RankingRun.find_by(id: ranking_run_id)
    return unless ranking_run

    ranking_run.with_lock do
      return if current_version_succeeded?(ranking_run)

      ranking_run.update!(
        title_ideas_status: "failed",
        title_ideas_version: TitleIdeas::Generator::VERSION,
        title_ideas_error: error.message.to_s.first(500)
      )
    end
  end

  def current_version_succeeded?(ranking_run)
    ranking_run.title_ideas_status == "succeeded" &&
      ranking_run.title_ideas_version == TitleIdeas::Generator::VERSION
  end
end
