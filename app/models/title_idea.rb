class TitleIdea < ApplicationRecord
  belongs_to :title_idea_set

  validates :rank, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :title, :angle, presence: true
  validates :evidence, hash_payload: true
  validate :title_word_count

  private

  def title_word_count
    count = title.to_s.split.length
    return if count.between?(4, 12)

    errors.add(:title, "must contain between 4 and 12 words")
  end
end
