class UsersController < ApplicationController
  before_action :require_signups_enabled
  rate_limit to: 5, within: 1.hour, only: :create

  def new
    redirect_to videos_path and return if logged_in?

    @user = User.new
  end

  def create
    @user = User.new(user_params)

    if @user.save
      reset_session
      session[:user_id] = @user.id
      redirect_to videos_path, notice: "Welcome to ClipRank."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def require_signups_enabled
    return if signups_enabled?

    redirect_to login_path, alert: "Account creation is disabled for this demo."
  end

  def user_params
    params.require(:user).permit(:name, :email, :password, :password_confirmation)
  end
end
