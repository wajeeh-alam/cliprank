class TranscriptSegment < ApplicationRecord
  belongs_to :video

  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :text, :transcript_version, presence: true
  validates :start_ms, :end_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :timestamp_range
  validate :word_timestamp_schema

  private

  def timestamp_range
    return if start_ms.blank? || end_ms.blank?

    errors.add(:end_ms, "must be greater than start_ms") unless start_ms < end_ms
  end

  def word_timestamp_schema
    return errors.add(:words, "must be an array") unless words.is_a?(Array)

    words.each do |word|
      unless word.is_a?(Hash) && word.key?("start_ms") && word.key?("end_ms") && word.key?("text")
        errors.add(:words, "must contain start_ms, end_ms, and text for each word")
        next
      end

      next unless word["start_ms"].is_a?(Numeric) && word["end_ms"].is_a?(Numeric)

      errors.add(:words, "word timestamps must have start_ms < end_ms") unless word["start_ms"] < word["end_ms"]
    end
  end
end
