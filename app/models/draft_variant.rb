class DraftVariant < ApplicationRecord
  PLATFORMS = %w[instagram linkedin].freeze

  enum :platform, PLATFORMS.index_by(&:itself), validate: true

  belongs_to :publishing_draft

  validates :title, :description, presence: true
  validates :title, length: { maximum: 255 }
  validates :cta, length: { maximum: 500 }, allow_blank: true
  validates :evidence, hash_payload: true
  validate :hashtags_are_strings
  validate :draft_is_editable

  private

  def hashtags_are_strings
    unless hashtags.is_a?(Array) && hashtags.all? { |tag| tag.is_a?(String) && tag.match?(/\A#[\p{L}\p{N}_]+\z/u) }
      errors.add(:hashtags, "must be an array of hashtags")
    end
  end

  def draft_is_editable
    return if publishing_draft.blank?
    return if publishing_draft.status.in?(%w[draft ready_for_review])
    return unless new_record? || has_changes_to_save?

    errors.add(:base, "approved publishing drafts cannot be edited")
  end
end
