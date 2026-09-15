class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_user, :logged_in?

  before_action :load_current_user

  private

  def current_user
    Current.user
  end

  def logged_in?
    current_user.present?
  end

  def require_authentication
    return if logged_in?

    redirect_to login_path, alert: "Please log in to continue."
  end

  def load_current_user
    Current.user = session[:user_id].present? ? User.find_by(id: session[:user_id]) : nil
  end
end
