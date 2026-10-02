class FeedbackDashboardController < ApplicationController
  before_action :require_authentication

  def show
    @publications = current_user.publications.includes(:metric_snapshots, :candidate_clip, :ranking_prediction)
      .order(published_at: :desc, id: :desc)
    @models = ModelVersion.order(created_at: :desc).limit(20)
    @labeled_count = @publications.count { |publication| publication.selected_outcome_snapshot.present? }
    @latest_model = @models.first
  end

  def import
    csv = if params[:csv_file].respond_to?(:read)
      raise ArgumentError, "CSV file is too large" if params[:csv_file].size.to_i > 1.megabyte
      params[:csv_file].read
    else
      params[:csv_text].to_s
    end
    result = Feedback::CsvImporter.call(
      user: current_user,
      platform: params.require(:platform),
      platform_account_key: params.require(:platform_account_key),
      csv: csv
    )
    message = "Imported #{result.created} snapshots; skipped #{result.duplicates} duplicates."
    message += " #{result.errors.length} rows had errors." if result.errors.any?
    redirect_to feedback_dashboard_path, notice: message
  rescue ArgumentError, ActionController::ParameterMissing => error
    redirect_to feedback_dashboard_path, alert: error.message
  end
end
