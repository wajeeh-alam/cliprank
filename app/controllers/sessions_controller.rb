class SessionsController < ApplicationController
  def new
    redirect_to videos_path and return if logged_in?

    @user = User.new
  end

  def create
    @user = User.find_by(email: params.dig(:session, :email).to_s.strip.downcase)

    if @user&.authenticate(params.dig(:session, :password).to_s)
      reset_session
      session[:user_id] = @user.id
      redirect_to videos_path, notice: "You are now logged in."
    else
      @user = User.new(email: params.dig(:session, :email))
      flash.now[:alert] = "Email or password is incorrect."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "You are now logged out."
  end
end
