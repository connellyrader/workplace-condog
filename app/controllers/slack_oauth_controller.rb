# app/controllers/slack_oauth_controller.rb
class SlackOauthController < ApplicationController
  before_action :authenticate_user!

  # STEP 1: Kick off the OAuth install flow with the chosen workspace
  def start
    workspace =
      if params[:workspace_id].present?
        current_user.workspaces.where(archived_at: nil).find_by(id: params[:workspace_id])
      else
        @active_workspace
      end

    unless workspace
      redirect_to dashboard_path, alert: "Please select a workspace before connecting Slack."
      return
    end

    oauth_nonce = oauth_state_begin!(provider: "slack", workspace_id: workspace.id)

    base = "https://slack.com/oauth/v2/authorize"
    qs = {
      client_id:    ENV.fetch("SLACK_CLIENT_ID"),
      scope:        bot_scopes,
      user_scope:   user_scopes,
      redirect_uri: slack_history_callback_url,
      state:        oauth_nonce
    }.to_query

    redirect_to "#{base}?#{qs}", allow_other_host: true
  end

  # STEP 2: Slack calls us back with ?code=…&state=<nonce>
  def callback
    code = params.require(:code)

    state_data   = oauth_state_verify!(provider: "slack", returned_state: params.require(:state))
    workspace_id = (state_data["workspace_id"] || state_data[:workspace_id]).to_i

    workspace = current_user.workspaces.where(archived_at: nil).find_by(id: workspace_id)
    unless workspace
      Rails.logger.warn "[Slack OAuth] Workspace not found or not accessible for session workspace_id=#{workspace_id}"
      redirect_to dashboard_path, alert: "Could not link Slack workspace."
      return
    end

    client = Slack::Web::Client.new
    oauth  = client.oauth_v2_access(
      client_id:     ENV.fetch("SLACK_CLIENT_ID"),
      client_secret: ENV.fetch("SLACK_CLIENT_SECRET"),
      code:          code,
      redirect_uri:  slack_history_callback_url
    )

    unless oauth["ok"]
      Rails.logger.error "[Slack OAuth] oauth_v2_access failed: #{oauth['error']}"
      redirect_to dashboard_path, alert: "Slack authentication failed."
      return
    end

    bot_token     = oauth["access_token"]
    user_token    = oauth.dig("authed_user", "access_token")
    installer_uid = oauth.dig("authed_user", "id") || oauth["bot_user_id"]

    team_info = Slack::Web::Client.new(token: user_token).team_info.fetch("team")
    slack_team_id = team_info["id"]
    team_name     = team_info["name"]
    team_domain   = team_info["domain"]

    integration = workspace.integrations.find_or_initialize_by(slack_team_id: slack_team_id)
    was_new = integration.new_record?

    integration.name         = team_name
    integration.domain       = team_domain
    integration.kind       ||= "slack"

    # Only set queued/status fields on FIRST install, otherwise keep existing state
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

    iu = integration.integration_users.find_or_initialize_by(slack_user_id: installer_uid)
    iu.user               ||= current_user
    iu.slack_history_token  = user_token
    iu.slack_bot_token      = bot_token
    # if you later support refresh: iu.slack_refresh_token = ...
    iu.save!

    # User is acting in a customer workspace context, not partner portal mode.
    session[:partner_mode] = false
    session[:active_workspace_id] = workspace.id

    if was_new
      # First-time install: do the full setup
      IntegrationSetupJob.perform_later(integration.id)
      Notifiers::WorkspaceWelcomeNotifier.call(workspace: workspace)
      redirect_to start_path, notice: "Connected Slack. Finishing setup…"
      return
    end

    # Existing integration: do NOT reset setup; just hydrate new access for this user
    SlackUserHydrationJob.perform_later(integration.id, iu.id)

    # If the workspace is already paid/active, send them back to integrations instead of onboarding.
    has_active_subscription =
      workspace.subscriptions.where(status: %w[active trialing]).exists?

    if has_active_subscription
      redirect_to integrations_path, notice: "Slack connected. Updating your access…"
    else
      # If not subscribed yet, you may still want to return to integrations (often better UX),
      # but keeping your original behavior is fine.
      redirect_to integrations_path, notice: "Slack connected. Updating your access…"
    end
  rescue => e
    Rails.logger.warn "[Slack OAuth] callback error: #{e.class} #{e.message}"
    redirect_to dashboard_path, alert: "Slack authentication failed."
  end


  private

  def bot_scopes
    %w[chat:write im:write mpim:write].join(",")
  end

  def user_scopes
    %w[
      channels:read channels:history groups:read groups:history
      im:read im:history mpim:read mpim:history
      users:read users:read.email team:read search:read
    ].join(",")
  end
end
