# app/controllers/users/omniauth_callbacks_controller.rb
class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  include Devise::Controllers::Rememberable

  def google_oauth2
    handle_basic_sso!
  end

  def entra_id
    handle_basic_sso!
  end

  # FLOW A: Sign in with Slack (OIDC)
  def slack_sso
    auth = request.env["omniauth.auth"]
    @user = User.from_slack_sso(auth)

    unless @user&.persisted?
      redirect_to new_user_session_url, alert: "Slack SSO failed. Please try again."
      return
    end

    apply_referral!(@user)

    # ✅ Universal SSO: store most recent sign-in method
    @user.update(auth_provider: "slack")

    raw       = auth.extra.raw_info
    team_id   = raw["https://slack.com/team_id"]
    slack_uid = auth.uid

    if team_id && slack_uid
      team_name   = raw["https://slack.com/team_name"]   || "New Workspace"
      team_domain = raw["https://slack.com/team_domain"] || "new-workspace"

      integration = Integration.find_by(slack_team_id: team_id)

      workspace =
        if integration
          integration.workspace
        else
          ws =
            @user.workspaces.where(archived_at: nil).order(:created_at).first ||
            @user.workspaces.create!(name: team_name)

          integration = ws.integrations.create!(
            slack_team_id: team_id,
            name:          team_name,
            domain:        team_domain,
            kind:          "slack",
            sync_status:   "queued"
          )

          ws
        end

      iu = integration.integration_users.find_or_initialize_by(slack_user_id: slack_uid)
      iu.user ||= @user

      if integration.integration_users.where(role: "owner").none?
        iu.role = "owner"
      elsif iu.role.blank?
        iu.role = "member"
      end

      iu.save!

      if workspace.respond_to?(:archived_at) && workspace.archived_at.present?
        session[:active_workspace_id] = nil
      else
        session[:active_workspace_id] = workspace.id
      end
    end

    remember_me(@user)
    sign_in @user, event: :authentication

    redirect_to stored_location_for(:user) || after_sign_in_path_for(@user)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[Slack SSO] RecordInvalid: #{e.record.errors.full_messages.join(", ")}")
    redirect_to new_user_session_url, alert: "Slack SSO failed. Please try again."
  rescue => e
    Rails.logger.warn("[Slack SSO] #{e.class}: #{e.message}")
    redirect_to new_user_session_url, alert: "Slack SSO failed. Please try again."
  end

  private

  # Google + Entra login-only SSO
  def handle_basic_sso!
    auth = request.env["omniauth.auth"]

    raw_email =
      auth&.dig("info", "email").presence ||
      auth&.dig("extra", "raw_info", "email").presence ||
      auth&.dig("extra", "raw_info", "preferred_username").presence

    email = raw_email.to_s.strip.downcase
    unless email.present?
      redirect_to new_user_session_url, alert: "SSO failed: no email address returned."
      return
    end

    provider =
      case auth&.provider.to_s
      when "google_oauth2" then "google"
      when "entra_id"      then "microsoft"
      else                     auth&.provider.to_s.presence
      end

    email_verified =
      auth&.dig("info", "verified") == true ||
      auth&.dig("extra", "raw_info", "email_verified") == true ||
      auth&.dig("extra", "raw_info", "verified_email") == true

    if auth&.provider.to_s == "google_oauth2" && email_verified == false
      redirect_to new_user_session_url, alert: "SSO failed: email address is not verified."
      return
    end

    user = User.where("LOWER(email) = ?", email).first_or_initialize
    user.email = email

    first = auth&.dig("info", "first_name").presence
    last  = auth&.dig("info", "last_name").presence
    full  = auth&.dig("info", "name").to_s.strip.presence

    if user.first_name.blank? && first.present?
      user.first_name = first
    elsif user.first_name.blank? && full.present?
      user.first_name = full.split(/\s+/).first
    end

    if user.last_name.blank? && last.present?
      user.last_name = last
    elsif user.last_name.blank? && full.present?
      parts = full.split(/\s+/)
      user.last_name = parts.length > 1 ? parts[1..].join(" ") : nil
    end

    user.password = Devise.friendly_token[0, 20] if user.new_record?
    user.auth_provider = provider
    user.save!

    apply_referral!(user)

    remember_me(user)
    sign_in user, event: :authentication

    redirect_to stored_location_for(:user) || after_sign_in_path_for(user)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[SSO #{auth&.provider}] RecordInvalid: #{e.record.errors.full_messages.join(", ")}")
    redirect_to new_user_session_url, alert: "SSO failed. Please try again."
  rescue => e
    Rails.logger.warn("[SSO #{auth&.provider}] #{e.class}: #{e.message}")
    redirect_to new_user_session_url, alert: "SSO failed. Please try again."
  end

  def apply_referral!(user)
    return unless cookies.signed[:referral_link_id].present?

    user.update(referred_by_link_id: cookies.signed[:referral_link_id])

    # Prefer attributing the click from this browser (click_uuid) if present.
    scope = LinkClick.where(link_id: cookies.signed[:referral_link_id], created_user_id: nil)

    if cookies[:click_uuid].present?
      scope.where(click_uuid: cookies[:click_uuid]).order(created_at: :desc).limit(1).update_all(created_user_id: user.id)
    else
      scope.order(created_at: :desc).limit(1).update_all(created_user_id: user.id)
    end

    cookies.delete(:referral_link_id)
  end
end
