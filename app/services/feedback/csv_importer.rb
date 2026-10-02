require "csv"

module Feedback
  class CsvImporter
    HEADERS = %w[post_id observed_at views likes comments shares saves average_watch_time_seconds retention_rate].freeze

    Result = Data.define(:created, :duplicates, :errors)

    def self.call(user:, platform:, platform_account_key:, csv:)
      new(user, platform, platform_account_key, csv).call
    end

    def initialize(user, platform, platform_account_key, csv)
      @user = user
      @platform = platform
      @platform_account_key = platform_account_key
      @csv = csv
    end

    def call
      created = duplicates = 0
      errors = []
      table = CSV.parse(@csv.to_s, headers: true)
      missing = %w[post_id observed_at views] - Array(table.headers)
      raise ArgumentError, "CSV is missing: #{missing.join(', ')}" if missing.any?

      table.each_with_index do |row, index|
        publication = @user.publications.find_by!(
          platform: @platform, platform_account_key: @platform_account_key, post_id: row["post_id"].to_s.strip
        )
        attributes = snapshot_attributes(publication, row)
        snapshot = publication.metric_snapshots.new(attributes)
        snapshot.valid?
        if MetricSnapshot.exists?(import_fingerprint: snapshot.import_fingerprint)
          duplicates += 1
        else
          snapshot.save!
          created += 1
        end
      rescue ActiveRecord::RecordNotUnique
        duplicates += 1
      rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ArgumentError => error
        errors << { "row" => index + 2, "message" => error.message }
      end
      Result.new(created, duplicates, errors)
    rescue CSV::MalformedCSVError => error
      raise ArgumentError, "CSV could not be parsed: #{error.message}"
    end

    private

    def snapshot_attributes(publication, row)
      observed_at = Time.zone.parse(row.fetch("observed_at").to_s)
      raise ArgumentError, "observed_at is invalid" unless observed_at

      metrics = HEADERS.index_with { |header| row[header] }.compact
      {
        observed_at: observed_at,
        source: "csv",
        source_record_id: "csv:#{publication.post_id}:#{observed_at.iso8601}",
        raw_metrics: metrics,
        demo_data: publication.demo_data,
        views: integer_or_nil(row["views"]),
        likes: integer_or_nil(row["likes"]),
        comments: integer_or_nil(row["comments"]),
        shares: integer_or_nil(row["shares"]),
        saves: integer_or_nil(row["saves"]),
        average_watch_time_seconds: decimal_or_nil(row["average_watch_time_seconds"]),
        retention_rate: decimal_or_nil(row["retention_rate"])
      }
    rescue ArgumentError
      raise ArgumentError, "numeric metric is invalid"
    end

    def integer_or_nil(value)
      value.present? ? Integer(value) : nil
    end

    def decimal_or_nil(value)
      value.present? ? BigDecimal(value) : nil
    end
  end
end
