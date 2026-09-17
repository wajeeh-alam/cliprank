class PublishingDraftsController < ApplicationController
  before_action :require_authentication
  before_action :set_draft, only: %i[show update ready approve]

  def index
    @publishing_drafts = PublishingDraft.where(user: current_user)
      .includes(:video, :candidate_clip, :draft_variants)
      .order(created_at: :desc, id: :desc)
  end

  def show
  end

  def create
    candidate = CandidateClip.joins(:video)
      .where(videos: { user_id: current_user.id })
      .find(params.require(:candidate_clip_id))
    draft = PublishingDraft.create!(user: current_user, video: candidate.video, candidate_clip: candidate)
    Publishing::ContentPackageGenerator.call(draft)
    redirect_to publishing_draft_path(draft), notice: "Instagram and LinkedIn drafts are ready to review."
  rescue ActiveRecord::RecordInvalid, Publishing::ContentPackageGenerator::Error => e
    redirect_back fallback_location: videos_path, alert: "The publishing draft could not be created: #{e.message}"
  end

  def update
    return unless ensure_editable!

    @draft.return_to_draft! if @draft.ready_for_review?
    PublishingDraft.transaction do
      variant_params.each_value do |attributes|
        variant = @draft.draft_variants.find(attributes.fetch(:id))
        variant.update!(attributes.except(:id).merge(hashtags: parse_hashtags(attributes[:hashtags])))
      end
    end
    redirect_to publishing_draft_path(@draft), notice: "Draft changes saved."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    flash.now[:alert] = "The draft could not be saved: #{e.message}"
    render :show, status: :unprocessable_entity
  end

  def ready
    return unless ensure_editable!

    @draft.mark_ready_for_review!
    redirect_to publishing_draft_path(@draft), notice: "Draft is ready for final review."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to publishing_draft_path(@draft), alert: "The draft is incomplete: #{e.message}"
  end

  def approve
    unless @draft.ready_for_review?
      return redirect_to publishing_draft_path(@draft), alert: "Mark the draft ready for review before approving it."
    end

    @draft.approve!
    redirect_to publishing_draft_path(@draft), notice: "Draft approved. Nothing has been published automatically."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to publishing_draft_path(@draft), alert: "The draft could not be approved: #{e.message}"
  end

  private

  def set_draft
    @draft = PublishingDraft.where(user: current_user)
      .includes(:video, :candidate_clip, :draft_variants)
      .find(params[:id])
  end

  def ensure_editable!
    return true if @draft.status.in?(%w[draft ready_for_review])

    redirect_to publishing_draft_path(@draft), alert: "Approved drafts are locked against further edits."
    false
  end

  def variant_params
    params.require(:draft_variants).to_unsafe_h.transform_values do |attributes|
      ActionController::Parameters.new(attributes).permit(:id, :title, :description, :hashtags, :cta).to_h.symbolize_keys
    end
  end

  def parse_hashtags(value)
    value.to_s.split(/[\s,]+/).filter_map do |tag|
      normalized = tag.strip.delete_prefix("#").gsub(/[^\p{L}\p{N}_]/u, "")
      "##{normalized}" if normalized.present?
    end.uniq
  end
end
