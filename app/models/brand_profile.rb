class BrandProfile < ApplicationRecord
  LIST_ATTRIBUTES = %i[content_pillars preferred_terms avoided_terms example_posts].freeze

  belongs_to :user

  validates :user_id, uniqueness: true
  validates :brand_name, presence: true, length: { maximum: 255 }
  validates :description, :audience, :voice, presence: true, length: { maximum: 5_000 }
  validates :default_cta, length: { maximum: 1_000 }
  validates(*LIST_ATTRIBUTES, array_payload: true)
  validate :list_items_are_present_strings

  private

  def list_items_are_present_strings
    LIST_ATTRIBUTES.each do |attribute|
      values = public_send(attribute)
      next unless values.is_a?(Array)
      next if values.all? { |value| value.is_a?(String) && value.present? }

      errors.add(attribute, "must contain only nonblank text values")
    end
  end
end
