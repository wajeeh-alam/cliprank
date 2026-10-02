class FeedbackModelsController < ApplicationController
  before_action :require_authentication
  before_action :require_operator

  def train
    platform = params.fetch(:platform, "instagram")
    unless ModelVersion::PLATFORMS.include?(platform)
      return redirect_to feedback_dashboard_path, alert: "Unsupported feedback platform."
    end

    TrainFeedbackModelJob.perform_later(platform)
    redirect_to feedback_dashboard_path, notice: "Feedback training queued. New models always start in shadow mode."
  end

  def activate
    model = ModelVersion.find(params[:id])
    unless model.evaluation_metrics.dig("release_gate", "eligible") == true
      return redirect_to feedback_dashboard_path, alert: "This model did not pass the held-out release gate and must remain in shadow mode."
    end

    model.activate!
    redirect_to feedback_dashboard_path, notice: "#{model.version} is active. Baseline fallback remains enabled."
  end

  def rollback
    target = ModelVersion.find(params[:id])
    unless target.evaluation_metrics.dig("release_gate", "eligible") == true
      return redirect_to feedback_dashboard_path, alert: "Rollback target has not passed the release gate."
    end

    target.activate!
    redirect_to feedback_dashboard_path, notice: "Rolled back to #{target.version}."
  end

  private

  def require_operator
    operator_email = ENV["FEEDBACK_OPERATOR_EMAIL"].to_s.downcase
    return if operator_email.blank? || ActiveSupport::SecurityUtils.secure_compare(current_user.email, operator_email)

    head :forbidden
  end
end
