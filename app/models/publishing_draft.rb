require "digest"

class PublishingDraft < ApplicationRecord
  STATUSES = %w[draft ready_for_review approved publishing published failed].freeze
  TRANSITIONS = {
    "draft" => %w[ready_for_review],
    "ready_for_review" => %w[draft approved],
    "approved" => %w[publishing ready_for_review],
    "publishing" => %w[published failed],
    "failed" => %w[approved publishing ready_for_review],
    "published" => []
  }.freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :user
  belongs_to :video
  belongs_to :candidate_clip
  has_many :draft_variants, dependent: :destroy

  validates :approved_payload_digest, :approved_at,
    presence: true, if: -> { status.in?(%w[approved publishing published failed]) }
  validates :error_message, length: { maximum: 2_000 }, allow_nil: true
  validate :video_belongs_to_user
  validate :candidate_belongs_to_video
  validate :valid_status_transition
  validate :variants_are_complete, if: -> { status.in?(%w[ready_for_review approved]) }

  def mark_ready_for_review!
    update!(status: "ready_for_review", error_message: nil)
  end

  def return_to_draft!
    update!(
      status: "draft",
      approved_at: nil,
      approved_payload_digest: nil,
      error_message: nil
    )
  end

  def approve!(at: Time.current)
    with_lock do
      update!(
        status: "approved",
        approved_at: at,
        approved_payload_digest: payload_digest,
        error_message: nil
      )
    end
  end

  def start_publishing!
    update!(status: "publishing", error_message: nil)
  end

  def mark_published!(at: Time.current)
    update!(status: "published", published_at: at, error_message: nil)
  end

  def mark_failed!(message:)
    update!(status: "failed", error_message: message.to_s.truncate(2_000))
  end

  def payload_digest
    payload = draft_variants.order(:platform, :id).map do |variant|
      {
        platform: variant.platform,
        title: variant.title,
        description: variant.description,
        hashtags: variant.hashtags,
        cta: variant.cta
      }
    end
    Digest::SHA256.hexdigest(JSON.generate(payload))
  end

  private

  def video_belongs_to_user
    return if video.blank? || user.blank? || video.user_id == user_id

    errors.add(:video, "must belong to the draft's user")
  end

  def candidate_belongs_to_video
    return if candidate_clip.blank? || video.blank? || candidate_clip.video_id == video_id

    errors.add(:candidate_clip, "must belong to the draft's video")
  end

  def valid_status_transition
    if new_record?
      errors.add(:status, "must start as draft") unless status == "draft"
      return
    end
    return unless will_save_change_to_status?

    previous_status = status_in_database
    return if TRANSITIONS.fetch(previous_status, []).include?(status)

    errors.add(:status, "cannot transition from #{previous_status} to #{status}")
  end

  def variants_are_complete
    variants = draft_variants.to_a
    errors.add(:draft_variants, "must include at least one platform") if variants.empty?
    errors.add(:draft_variants, "must be complete") if variants.any?(&:invalid?)
  end
end
