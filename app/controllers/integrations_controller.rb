class IntegrationsController < ApplicationController
  before_action :require_authentication
  class_attribute :instagram_client_factory, default: -> { Instagram::Client.new }
  class_attribute :linkedin_client_factory, default: -> { Linkedin::Client.new }

  def show
    @instagram_accounts = current_user.instagram_accounts.includes(instagram_media: :instagram_insight_snapshots)
    @linkedin_accounts = current_user.linkedin_accounts.includes(linkedin_posts: :linkedin_insight_snapshots)
  end

  def instagram_connect
    state = SecureRandom.urlsafe_base64(32)
    session[:instagram_oauth_state] = {
      "value" => state,
      "user_id" => current_user.id,
      "created_at" => Time.current.to_i
    }
    redirect_to instagram_client.authorization_url(state: state), allow_other_host: true
  rescue Instagram::Client::ConfigurationError
    redirect_to integrations_path, alert: "Instagram integration is not configured yet."
  end

  def instagram_callback
    state = session.delete(:instagram_oauth_state)
    unless valid_oauth_state?(state, params[:state])
      return redirect_to integrations_path, alert: "Instagram authorization expired. Please try again."
    end

    if params[:error].present? || params[:code].blank?
      return redirect_to integrations_path, alert: "Instagram authorization was not completed."
    end

    client = instagram_client
    short_lived = client.exchange_code(code: params[:code].to_s)
    long_lived = client.exchange_long_lived_token(access_token: short_lived.fetch("access_token"))
    profile = client.profile(access_token: long_lived.fetch("access_token"))
    account_type = profile["account_type"].to_s.upcase
    unless InstagramAccount::ACCOUNT_TYPES.include?(account_type)
      return redirect_to integrations_path, alert: "Only Instagram Business and Creator accounts are supported."
    end

    account = current_user.instagram_accounts.find_or_initialize_by(instagram_user_id: profile.fetch("user_id").to_s)
    account.assign_attributes(
      username: profile.fetch("username").to_s,
      account_type: account_type,
      token_expires_at: token_expiry(long_lived),
      sync_error: nil
    )
    account.access_token = long_lived.fetch("access_token")
    account.save!
    InstagramSyncJob.perform_later(account.id)
    redirect_to integrations_path, notice: "Instagram account connected. Sync has started."
  rescue KeyError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Instagram::Client::Error
    redirect_to integrations_path, alert: "Instagram could not be connected. Please try again."
  end

  def instagram_sync
    account = current_user.instagram_accounts.find(params[:id])
    InstagramSyncJob.perform_later(account.id)
    redirect_to integrations_path, notice: "Instagram sync queued."
  end

  def instagram_disconnect
    account = current_user.instagram_accounts.find(params[:id])
    account.destroy!
    redirect_to integrations_path, notice: "Instagram account disconnected."
  end

  def linkedin_connect
    state = SecureRandom.urlsafe_base64(32)
    session[:linkedin_oauth_state] = {
      "value" => state,
      "user_id" => current_user.id,
      "created_at" => Time.current.to_i
    }
    redirect_to linkedin_client.authorization_url(state: state), allow_other_host: true
  rescue Linkedin::Client::ConfigurationError
    redirect_to integrations_path, alert: "LinkedIn integration is not configured yet."
  end

  def linkedin_callback
    state = session.delete(:linkedin_oauth_state)
    unless valid_oauth_state?(state, params[:state])
      return redirect_to integrations_path, alert: "LinkedIn authorization expired. Please try again."
    end

    if params[:error].present? || params[:code].blank?
      return redirect_to integrations_path, alert: "LinkedIn authorization was not completed."
    end

    token_payload = linkedin_client.exchange_code(code: params[:code].to_s)
    profile = linkedin_client.profile(access_token: token_payload.fetch("access_token"))
    account = current_user.linkedin_accounts.find_or_initialize_by(linkedin_member_id: profile.fetch("sub").to_s)
    account.assign_attributes(
      display_name: profile["name"].presence || "LinkedIn member",
      token_expires_at: token_expiry(token_payload),
      sync_error: nil
    )
    account.access_token = token_payload.fetch("access_token")
    account.save!
    LinkedinSyncJob.perform_later(account.id)
    redirect_to integrations_path, notice: "LinkedIn account connected. Sync has started."
  rescue KeyError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Linkedin::Client::Error
    redirect_to integrations_path, alert: "LinkedIn could not be connected. Please try again."
  end

  def linkedin_sync
    account = current_user.linkedin_accounts.find(params[:id])
    LinkedinSyncJob.perform_later(account.id)
    redirect_to integrations_path, notice: "LinkedIn sync queued."
  end

  def linkedin_disconnect
    account = current_user.linkedin_accounts.find(params[:id])
    account.destroy!
    redirect_to integrations_path, notice: "LinkedIn account disconnected."
  end

  private

  def instagram_client
    self.class.instagram_client_factory.call
  end

  def linkedin_client
    self.class.linkedin_client_factory.call
  end

  def valid_oauth_state?(stored, returned)
    return false unless stored.is_a?(Hash) && returned.present?
    return false unless stored["user_id"].to_i == current_user.id
    return false if stored["created_at"].to_i < 10.minutes.ago.to_i

    ActiveSupport::SecurityUtils.secure_compare(stored["value"].to_s, returned.to_s)
  end

  def token_expiry(payload)
    seconds = payload["expires_in"].to_i
    seconds.positive? ? Time.current + seconds.seconds : nil
  end
end
