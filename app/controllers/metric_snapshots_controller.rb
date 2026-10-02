class MetricSnapshotsController < ApplicationController
  before_action :require_authentication
  before_action :set_publication

  def create
    @snapshot = @publication.metric_snapshots.new(snapshot_params.merge(
      source: "manual", raw_metrics: snapshot_params.to_h, demo_data: @publication.demo_data
    ))
    if @snapshot.save
      redirect_to publication_path(@publication), notice: outcome_notice(@snapshot)
    else
      render "publications/show", status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to publication_path(@publication), alert: "That metric snapshot was already imported."
  end

  private

  def set_publication
    @publication = current_user.publications.includes(:metric_snapshots, :ranking_prediction).find(params[:publication_id])
  end

  def snapshot_params
    params.require(:metric_snapshot).permit(
      :observed_at, :views, :likes, :comments, :shares, :saves,
      :average_watch_time_seconds, :retention_rate
    )
  end

  def outcome_notice(snapshot)
    snapshot.mature? ? "Snapshot saved and eligible for the 72-hour outcome." : "Snapshot saved, but it is not a valid 60–84 hour outcome."
  end
end
