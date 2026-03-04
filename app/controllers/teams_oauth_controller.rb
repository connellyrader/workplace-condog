# app/controllers/teams_oauth_controller.rb
class TeamsOauthController < ApplicationController
  before_action :authenticate_user!, except: [:admin_consent_callback, :admin_intro]

  skip_before_action :lucas_only, :set_active_workspace,
                     only: [:admin_consent_callback, :admin_intro]

  # Helper to build a state string from workspace/user for admin intro (legacy)
  def self.build_admin_state(workspace_id, user_id)
    ["admin_consent", "w#{workspace_id}", "u#{user_id}"].join(":")
  end

  # ========= public “explain to admin” page =========
  def admin_intro
    @onboarding = true
    @raw_state  = params[:state].to_s
    @workspace  = nil
    @requester  = nil

    if @raw_state.present?
      payload = decrypt_admin_state(@raw_state)
      if payload
        @workspace = Workspace.find_by(id: payload[:w])
        @requester = User.find_by(id: payload[:u])
      else
        Rails.logger.warn "[Teams OAuth] admin_intro: invalid state token"
      end
    end

    @ms_admin_consent_url = admin_consent_ms_url(@raw_state)
    render :admin_intro
  end

  # ========= admin consent callback =========
  def admin_consent_callback
    @onboarding = true

    if params[:error].present?
      Rails.logger.error "[Teams OAuth] admin consent error=#{params[:error]} desc=#{params[:error_description]}"
      @status = :error
    else
      @status    = :ok
      @tenant_id = params[:tenant]
      @scopes    = params[:scope]
      @consented = params[:admin_consent] == "True"

      @workspace = nil
      @requester = nil

      if params[:state].present?
        payload = decrypt_admin_state(params[:state])
        if payload
          @workspace = Workspace.find_by(id: payload[:w])
          @requester = User.find_by(id: payload[:u])
        else
          Rails.logger.warn "[Teams OAuth] admin_consent_callback: invalid state token"
        end
      end
    end

    if @status == :ok && @consented && @requester
      if @workspace
        @workspace.update!(ms_teams_admin_approved_at: Time.current)
      end
      Notifiers::TeamsAdminApprovalNotifier.call(user: @requester)
    end

    render :admin_consent_thanks
  end

  # ========= Step 1: send user to Microsoft identity platform =========
  def start
    workspace =
      if params[:workspace_id].present?
        current_user.workspaces.where(archived_at: nil).find_by(id: params[:workspace_id])
      else
        @active_workspace
      end

    unless workspace
      redirect_to dashboard_path, alert: "Please select a workspace before connecting Microsoft Teams."
      return
    end

    oauth_nonce = oauth_state_begin!(provider: "teams", workspace_id: workspace.id)

    auth_params = {
      client_id:     ENV.fetch("TEAMS_CLIENT_ID"),
      response_type: "code",
      redirect_uri:  teams_oauth_callback_url,
      response_mode: "query",
      scope: %w[
        offline_access
        User.Read
        User.Read.All
        Group.Read.All
        Channel.ReadBasic.All
        ChannelMember.Read.All
        ChannelMessage.Read.All
        ChannelMessage.Send
        TeamMember.Read.All
        Chat.Read
        ChatMessage.Send
        Chat.ReadWrite
        Reports.Read.All
      ].join(" "),
      state: oauth_nonce
    }

    authorize_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?#{auth_params.to_query}"
    redirect_to authorize_url, allow_other_host: true
  end

  # ========= Step 2: Microsoft sends us ?code=...&state=<nonce> OR ?error=... =========
  def callback
    if params[:error].present?
      Rails.logger.error "[Teams OAuth] error=#{params[:error]} desc=#{params[:error_description]}"

      if admin_consent_required?(params)
        redirect_to dashboard_path,
          alert: "Your Microsoft 365 admin needs to approve Workplace.io before you can connect. " \
                 "Send them the admin approval link shown on this page and try again after they confirm."
      else
        redirect_to dashboard_path, alert: "Microsoft Teams authentication was cancelled."
      end
      return
    end

    code = params.require(:code)

    state_data   = oauth_state_verify!(provider: "teams", returned_state: params.require(:state))
    workspace_id = (state_data["workspace_id"] || state_data[:workspace_id]).to_i

    workspace = current_user.workspaces.where(archived_at: nil).find_by(id: workspace_id)
    unless workspace
      Rails.logger.warn "[Teams OAuth] workspace not found for session workspace_id=#{workspace_id}"
      redirect_to dashboard_path, alert: "Could not link Microsoft Teams workspace."
      return
    end

    token_data = exchange_code_for_token(code)
    unless token_data && token_data["access_token"].present?
      Rails.logger.error "[Teams OAuth] token exchange failed"
      redirect_to dashboard_path, alert: "Could not complete Microsoft Teams connection."
      return
    end

    access_token   = token_data["access_token"]
    refresh_token  = token_data["refresh_token"]
    expires_in     = token_data["expires_in"].to_i
    expires_at     = Time.current + expires_in.seconds

    org_info     = fetch_organization_info(access_token)
    tenant_id    = org_info&.dig("value", 0, "id")
    tenant_name  = org_info&.dig("value", 0, "displayName") || "Microsoft 365 Tenant"

    me_info      = fetch_me_info(access_token)
    ms_user_id   = me_info["id"]
    ms_email     = me_info["mail"].presence || me_info["userPrincipalName"]
    ms_name      = me_info["displayName"].presence || ms_email

    integration = workspace.integrations.find_or_initialize_by(
      kind: "microsoft_teams",
      ms_tenant_id: tenant_id
    )
    was_new = integration.new_record?

    # Always keep tenant display info fresh
    integration.ms_tenant_id     = tenant_id
    integration.ms_display_name  = tenant_name
    integration.name           ||= tenant_name
    integration.kind           ||= "microsoft_teams"

    # ONLY initialize setup/sync fields on first install
    if was_new
      integration.sync_status ||= "queued"

      if integration.respond_to?(:setup_status=)
        integration.setup_status   = "queued"
        integration.setup_progress = 0 if integration.respond_to?(:setup_progress=)
        integration.setup_error    = nil if integration.respond_to?(:setup_error=)
        integration.setup_step     = "queued" if integration.respond_to?(:setup_step=)
      end
    end

    integration.save!

    iu = integration.integration_users.find_or_initialize_by(slack_user_id: ms_user_id)
    iu.user             ||= current_user
    iu.display_name     ||= ms_name
    iu.real_name        ||= ms_name
    iu.email            ||= ms_email
    iu.ms_access_token   = access_token
    iu.ms_refresh_token  = refresh_token
    iu.ms_expires_at     = expires_at
    iu.is_bot            = false if iu.has_attribute?(:is_bot)
    iu.active            = true  if iu.has_attribute?(:active)
    iu.save!

    # User is acting in a customer workspace context, not partner portal mode.
    session[:partner_mode] = false
    session[:active_workspace_id] = workspace.id

    if was_new
      # First-time install: full setup + initial sync
      IntegrationSetupJob.perform_later(integration.id)
      TeamsSyncJob.perform_later(integration.id)
      Notifiers::WorkspaceWelcomeNotifier.call(workspace: workspace)
      redirect_to start_path, notice: "Connected Microsoft Teams. Finishing setup…"
      return
    end

    # Existing integration: lightweight hydration ONLY (no resets)
    TeamsUserHydrationJob.perform_later(integration.id, iu.id)

    redirect_to integrations_path, notice: "Microsoft Teams connected. Updating your access…"
  rescue => e
    Rails.logger.error "[Teams OAuth] callback error: #{e.class} #{e.message}"
    redirect_to dashboard_path, alert: "There was a problem connecting Microsoft Teams."
  end


  private

  def admin_consent_ms_url(state)
    client_id    = ENV.fetch("TEAMS_CLIENT_ID")
    redirect_uri = teams_oauth_admin_consent_callback_url

    scopes = %w[
      offline_access
      User.Read
      User.Read.All
      Group.Read.All
      Channel.ReadBasic.All
      ChannelMember.Read.All
      ChannelMessage.Read.All
      ChannelMessage.Send
      TeamMember.Read.All
      Chat.Read
      ChatMessage.Send
      Chat.ReadWrite
      Reports.Read.All
    ].join(" ")

    params = {
      client_id:    client_id,
      redirect_uri: redirect_uri,
      state:        state,
      scope:        scopes
    }

    "https://login.microsoftonline.com/organizations/v2.0/adminconsent?#{params.to_query}"
  end

  def exchange_code_for_token(code)
    uri = URI("https://login.microsoftonline.com/common/oauth2/v2.0/token")

    body = {
      client_id:     ENV.fetch("TEAMS_CLIENT_ID"),
      client_secret: ENV.fetch("TEAMS_CLIENT_SECRET"),
      grant_type:    "authorization_code",
      code:          code,
      redirect_uri:  teams_oauth_callback_url
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Rails.env.development?

    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(body)

    response = http.request(request)
    JSON.parse(response.body)
  rescue => e
    Rails.logger.error "[Teams OAuth] token exchange error: #{e.class} #{e.message}"
    nil
  end

  def fetch_organization_info(access_token)
    uri = URI("https://graph.microsoft.com/v1.0/organization")

    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{access_token}"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Rails.env.development?

    res = http.request(req)
    JSON.parse(res.body)
  rescue => e
    Rails.logger.error "[Teams OAuth] org info error: #{e.class} #{e.message}"
    nil
  end

  def fetch_me_info(access_token)
    uri = URI("https://graph.microsoft.com/v1.0/me")

    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{access_token}"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Rails.env.development?

    res = http.request(req)
    JSON.parse(res.body)
  rescue => e
    Rails.logger.error "[Teams OAuth] me info error: #{e.class} #{e.message}"
    {}
  end

  def admin_consent_required?(params)
    desc = params[:error_description].to_s

    params[:error] == "access_denied" && (
      desc.include?("AADSTS90094") ||
      desc.include?("AADSTS65004") ||
      desc.downcase.include?("admin consent") ||
      desc.downcase.include?("consent required")
    )
  end
end
