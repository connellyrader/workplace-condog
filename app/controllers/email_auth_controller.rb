# app/controllers/email_auth_controller.rb
class EmailAuthController < ApplicationController
  # Public endpoints (login/signup). Do not require an authenticated session.
  skip_before_action :authenticate_user!, raise: false
  skip_before_action :lucas_only, raise: false
  skip_before_action :set_active_workspace, raise: false
  skip_before_action :ensure_workspace_ready!, raise: false
  skip_before_action :set_layout_defaults, raise: false
  skip_before_action :set_logit_margin_threshold, raise: false
  skip_before_action :set_right_panel_flags, raise: false

  # -----------------------------------------
  # POST /auth/email/lookup
  #
  # Returns one of:
  #  - { ok:true, status:"password" }
  #  - { ok:true, status:"sso", provider:"google_oauth2", sso_url:"/users/auth/google_oauth2", message:"..." }
  #  - { ok:true, status:"unknown" }
  #  - { ok:false, status:"invalid", error:"..." } (422)
  #
  # Note: This endpoint intentionally enables email-based branching (required for your UX).
  # Protect with Rack::Attack / throttling to mitigate enumeration.
  # -----------------------------------------
  def lookup
    email = normalize_email(extract_email_param)

    if email.blank?
      return render json: { ok: false, status: "invalid", error: "Enter a valid email address." }, status: :unprocessable_entity
    end

    # Small jitter; throttling is the real protection.
    sleep(rand * 0.12) if Rails.env.production?

    user = User.find_by(email: email)

    if user.nil?
      return render json: { ok: true, status: "unknown" }
    end

    provider = (user.respond_to?(:auth_provider) ? user.auth_provider.to_s : "").presence || infer_provider(user)

    if provider == "password"
      return render json: { ok: true, status: "password" }
    end

    provider = normalize_provider(provider)

    render json: {
      ok: true,
      status: "sso",
      provider: provider,
      sso_url: sso_url_for(provider),
      message: "This account uses Single Sign On. Continue with your provider."
    }
  rescue => e
    Rails.logger.warn("[EmailAuth] lookup failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "Lookup failed." }, status: :unprocessable_entity
  end

  # -----------------------------------------
  # POST /auth/email/password_sign_in
  # Params: email, password
  # Returns: { ok:true, redirect_url:"..." } or { ok:false, error:"..." }
  # -----------------------------------------
  def password_sign_in
    email    = normalize_email(extract_email_param)
    password = extract_password_param.to_s

    if email.blank? || password.blank?
      return render json: { ok: false, error: "Enter your email and password." }, status: :unprocessable_entity
    end

    user = User.find_by(email: email)
    return render json: { ok: false, error: "Invalid email or password." }, status: :unauthorized unless user

    provider = (user.respond_to?(:auth_provider) ? user.auth_provider.to_s : "").presence || infer_provider(user)

    # If they are SSO-only, do not allow password sign-in.
    if provider != "password"
      normalized = normalize_provider(provider)
      return render json: {
        ok: false,
        error: "This account uses Single Sign On.",
        status: "sso",
        provider: normalized,
        sso_url: sso_url_for(normalized)
      }, status: :forbidden
    end

    unless user.valid_password?(password)
      return render json: { ok: false, error: "Invalid email or password." }, status: :unauthorized
    end

    # Ensure provider is set for legacy users
    if user.respond_to?(:auth_provider) && user.auth_provider.blank?
      user.update_column(:auth_provider, "password")
    end

    sign_in(:user, user)

    render json: { ok: true, redirect_url: post_auth_redirect_url }
  rescue => e
    Rails.logger.warn("[EmailAuth] password_sign_in failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "Sign in failed." }, status: :unprocessable_entity
  end

  # -----------------------------------------
  # POST /auth/email/sign_up
  # Params: email, first_name, last_name, password, password_confirmation
  # Returns: { ok:true, redirect_url:"..." } or { ok:false, error:"..." }
  # -----------------------------------------
  def sign_up
    email = normalize_email(extract_email_param)

    first_name = extract_param(:first_name).to_s.strip
    last_name  = extract_param(:last_name).to_s.strip
    password   = extract_param(:password).to_s
    password_confirmation = extract_param(:password_confirmation).to_s

    return render json: { ok: false, error: "Enter a valid email address." }, status: :unprocessable_entity if email.blank?
    return render json: { ok: false, error: "First name is required." }, status: :unprocessable_entity if first_name.blank?
    return render json: { ok: false, error: "Last name is required." }, status: :unprocessable_entity if last_name.blank?
    return render json: { ok: false, error: "Password is required." }, status: :unprocessable_entity if password.blank?
    return render json: { ok: false, error: "Passwords do not match." }, status: :unprocessable_entity if password != password_confirmation

    if User.exists?(email: email)
      return render json: { ok: false, error: "That email is already registered." }, status: :conflict
    end

    user = User.new(
      email: email,
      first_name: first_name,
      last_name: last_name,
      password: password,
      password_confirmation: password_confirmation
    )

    user.auth_provider = "password" if user.respond_to?(:auth_provider=)

    if user.save
      sign_in(:user, user)
      render json: { ok: true, redirect_url: post_auth_redirect_url }
    else
      render json: { ok: false, error: user.errors.full_messages.first || "Unable to create account." },
             status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.warn("[EmailAuth] sign_up failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "Sign up failed." }, status: :unprocessable_entity
  end

  private

  # If the user came from an invite link, return them to the invite landing page.
  # Otherwise default to dashboard.
  #
  # Also clears the invite cookie so we don't force redirects forever.
  def post_auth_redirect_url
    token = cookies.signed[:pending_invite_token].presence
    if token.present?
      cookies.delete(:pending_invite_token)
      invite_path(token)
    else
      dashboard_path
    end
  end

  # Accept a few common param shapes:
  # - { email: "x@y.com" }
  # - { user: { email: "x@y.com" } }
  # - { email_auth: { email: "x@y.com" } }
  def extract_email_param
    params[:email].presence ||
      params.dig(:user, :email).presence ||
      params.dig(:email_auth, :email).presence
  end

  # Similar flexibility for password
  def extract_password_param
    params[:password].presence ||
      params.dig(:user, :password).presence ||
      params.dig(:email_auth, :password).presence
  end

  # Generic extractor for sign_up payload keys, supporting nested shapes too
  def extract_param(key)
    params[key].presence ||
      params.dig(:user, key).presence ||
      params.dig(:email_auth, key).presence
  end

  def normalize_email(val)
    email = val.to_s.strip.downcase
    return "" unless email.match?(URI::MailTo::EMAIL_REGEXP)
    email
  end

  # Map whatever you store in auth_provider to the OmniAuth provider keys your app uses.
  def normalize_provider(provider)
    p = provider.to_s

    return "google_oauth2" if p == "google" || p == "google_sso"
    return "entra_id"      if p == "microsoft" || p == "azure" || p == "azure_ad"
    return "slack_sso"     if p == "slack"

    p
  end

  def infer_provider(user)
    return "password" if user.encrypted_password.present?

    # If the user has no password, treat them as SSO-only.
    # Default to a stable provider if you can't infer.
    "google_oauth2"
  end

  def sso_url_for(provider)
    case provider.to_s
    when "google_oauth2" then "/users/auth/google_oauth2"
    when "entra_id"      then "/users/auth/entra_id"
    when "slack_sso"     then "/users/auth/slack_sso"
    else "/users/auth/google_oauth2"
    end
  end
end
