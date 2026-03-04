# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  rescue_from ActiveRecord::RecordNotFound do
    respond_to do |format|
      format.html { redirect_to "/404" }
      format.json { render json: { ok: false, error: "not_found" }, status: :not_found }
      format.any  { head :not_found }
    end
  end
  before_action :authenticate_user!
  before_action :lucas_only
  before_action :redirect_to_pending_invite!, if: :user_signed_in?
  before_action :redirect_partner_profile_to_partner_portal, if: :user_signed_in?
  before_action :set_active_workspace, if: :user_signed_in?
  before_action :set_layout_defaults
  before_action :set_unread_insights, if: :user_signed_in?
  before_action :enforce_demo_read_only!, if: :user_signed_in?
  before_action :set_logit_margin_threshold
  before_action :set_right_panel_flags
  before_action :redirect_restricted_users!, if: :user_signed_in? # for role "user"
  before_action :ensure_workspace_ready!
  before_action :configure_permitted_parameters, if: :devise_controller?

  helper_method :teams_admin_consent_url
  helper_method :show_chat_panel?, :show_analyze_panel?
  helper_method :encrypt_admin_state
  helper_method :workspace_admin?
  helper_method :available_workspaces

  # used for making unguessable, session-bound OAuth states so we dont reveal workspace id's in browser
  OAUTH_STATE_TTL = 10.minutes

  # ------------ ONBOARDING / ACCESS RULES ------------

  PAGE_RULES = {
    "dashboard" => {
      "workspace_pending" => { min_stage: 0, modal: false },
      "not_lucas"         => { min_stage: 0, modal: false },
      "test"              => { min_stage: 0, modal: false },
    },

    "settings" => {
      "index"          => { min_stage: 0, modal: false },
      "integrations"   => { min_stage: 0, modal: false },
      "cookie_settings"=> { min_stage: 0, modal: false },
      # Keep compatibility if/when this action name is used for the same page.
      "privacy"        => { min_stage: 0, modal: false },
      "notifications"  => { min_stage: 1, modal: true },
    },
  }.freeze

  DEFAULT_PAGE_RULE = { min_stage: 2, modal: true }.freeze

  def workspace_admin?
    return false unless defined?(@active_workspace) && @active_workspace && current_user

    # Demo workspace is intentionally fully explorable in Settings regardless of role.
    return true if demo_workspace_active?

    wu = @active_workspace.workspace_users.find_by(user_id: current_user.id)
    return false unless wu

    wu.is_owner? || %w[owner admin].include?(wu.role)
  end

  def ensure_workspace_ready!
    return if devise_controller?
    return unless request.format.html?

    # Admin pages should not be gated by onboarding/integration modals.
    return if controller_path == "admin" || controller_path.start_with?("admin/")

    # ✅ Controllers that must bypass workspace gating
    return if controller_path.in?(%w[
      slack_oauth
      teams_oauth
      onboarding
      workspaces
      invites
      email_auth
    ]) || controller_path.start_with?("partners/")

    # ✅ Allow user-role integration flow pages even if workspace isn't ready
    if controller_name == "users" && action_name.in?(%w[user_integrate user_done])
      return
    end

    ws = @active_workspace
    return unless ws && current_user

    stage  = workspace_stage
    rule   = page_rule
    needed = rule[:min_stage].to_i
    modal  = rule[:modal]

    return if stage >= needed

    is_admin_for_workspace = admin_for_workspace?(ws)

    if stage == 0 && needed >= 1
      if is_admin_for_workspace
        if modal
          @show_integration_modal = true
          return
        else
          redirect_to integrations_path,
                      alert: "Connect an integration (e.g. Slack or Teams) to get your workspace ready."
        end
      else
        redirect_to workspace_pending_path
      end
      return
    end

    if needed >= 2
      if is_admin_for_workspace
        has_full_group =
          Group
            .where(workspace_id: ws.id)
            .joins(:integration_users)
            .group("groups.id")
            .having("COUNT(integration_users.id) >= 3")
            .exists?

        if has_full_group
          redirect_to plan_path, alert: "Pick a plan to unlock full access for your team."
        else
          redirect_to start_path, alert: "Finish setting up your workspace to view the dashboard."
        end
      else
        redirect_to workspace_pending_path
      end
      return
    end
  end


  # Single, correct definition (removes your duplicate that was overriding this)
  def after_sign_in_path_for(resource)
    # Invite token should win for everyone (including partners), so users can
    # accept/decline immediately after auth.
    token = cookies.signed[:pending_invite_token].presence
    if token
      cookies.delete(:pending_invite_token)
      return invite_path(token)
    end

    if resource.respond_to?(:partner?) && resource.partner?
      return partner_dashboard_path
    end

    super
  end

  def after_sign_out_path_for(resource_or_scope)
    if resource_or_scope == :user && request.path.start_with?("/partner")
      new_partner_session_path
    else
      super
    end
  end

  # If a logged-in user has a pending invite (by email), redirect them to the
  # pending invite page so they can accept/decline without needing the email token.
  def redirect_to_pending_invite!
    return if devise_controller?
    return unless request.format.html?

    # Don't loop on invite screens.
    return if controller_name == "invites"

    email = current_user&.email.to_s.strip.downcase
    return if email.blank?

    pending =
      WorkspaceInvite
        .where(email: email)
        .pending_status
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
        .exists?

    redirect_to pending_invites_path if pending
  end

  private


  def redirect_restricted_users!
    return if devise_controller?
    return unless request.format.html?
    return unless current_user && @active_workspace

    restricted =
      %w[dashboard ai_chat insights clara docs].include?(controller_name)

    return unless restricted

    # Admins/owners behave normally
    return if workspace_admin?

    wu = @active_workspace.workspace_users.find_by(user_id: current_user.id)
    return unless wu
    return unless wu.role.to_s == "user"

    # ------------------------------------------------------------
    # ✅ USER-LEVEL integration check (not workspace-level)
    # ------------------------------------------------------------
    user_has_token =
      current_user.integration_users
        .joins(:integration)
        .where(integrations: { workspace_id: @active_workspace.id })
        .where(<<~SQL.squish)
          COALESCE(integration_users.slack_history_token, '') <> '' OR
          COALESCE(integration_users.slack_refresh_token, '') <> '' OR
          COALESCE(integration_users.slack_bot_token, '') <> '' OR
          COALESCE(integration_users.ms_refresh_token, '') <> ''
        SQL
        .exists?

    if user_has_token
      return if request.path == user_done_path
      redirect_to user_done_path and return
    else
      return if request.path == user_integrate_path
      redirect_to user_integrate_path and return
    end
  end



  def require_workspace_admin!
    unless workspace_admin?
      respond_to do |format|
        format.html do
          redirect_to notifications_path, alert: "You don’t have access to that settings page."
        end
        format.json do
          render json: { ok: false, error: "Not authorized." }, status: :forbidden
        end
      end
    end
  end

  def workspace_stage
    ws = @active_workspace
    return 0 unless ws

    has_integrations = Integration.where(workspace_id: ws.id).exists?
    has_subscription = ws.subscriptions.where(status: %w[active trialing]).exists?

    return 2 if has_subscription
    return 1 if has_integrations
    0
  end

  def page_rule
    controller_rules = PAGE_RULES[controller_name] || {}
    controller_rules[action_name] || controller_rules["*"] || DEFAULT_PAGE_RULE
  end

  def admin_for_workspace?(ws)
    return false unless ws && current_user

    is_workspace_owner =
      ws.owner_id.present? && ws.owner_id == current_user.id

    is_workspace_owner_via_join =
      WorkspaceUser.exists?(workspace_id: ws.id,
                            user_id: current_user.id,
                            is_owner: true)

    is_global_admin = current_user.respond_to?(:admin?) && current_user.admin?

    is_workspace_owner || is_workspace_owner_via_join || is_global_admin
  end

  def user_can_access_demo_workspace?
    return false unless current_user

    is_partner = current_user.respond_to?(:partner?) && current_user.partner?
    is_admin   = current_user.respond_to?(:admin?) && current_user.admin?

    is_partner || is_admin
  end

  def demo_workspace
    @demo_workspace ||= Workspace.find_by(name: DemoData::Generator::DEMO_WORKSPACE_NAME)
  end

  def available_workspaces
    return [] unless current_user

    @available_workspaces ||= begin
      workspaces = current_user.workspaces.where(archived_at: nil).order("workspaces.created_at ASC").to_a

      if user_can_access_demo_workspace?
        dw = demo_workspace
        if dw && dw.archived_at.nil? && !workspaces.any? { |w| w.id == dw.id }
          workspaces << dw
        end
      end

      workspaces
    end
  end

  def set_active_workspace
    return unless current_user

    # Partner-mode is a session-level context switch.
    # - Partners should default to partner mode on a fresh session/login.
    # - Switching to a customer workspace should turn it off (see WorkspacesController#switch).
    # - Navigating into /partner(s) routes should turn it on.
    prev_partner_mode = session[:partner_mode]

    if current_user.respond_to?(:partner?) && current_user.partner?
      desired_partner_mode =
        session[:partner_mode].nil? || request.path.start_with?("/partner", "/partners") || session[:partner_mode]

      session[:partner_mode] = !!desired_partner_mode

      # Option B: when entering partner mode, clear the active customer workspace.
      # This prevents UI/filters from "snapping back" to a prior client workspace unless
      # the user explicitly switches via the workspace switcher.
      if session[:partner_mode] && !prev_partner_mode
        if session[:active_workspace_id].present?
          session[:last_customer_workspace_id] = session[:active_workspace_id]
          session.delete(:active_workspace_id)
        end
      end
    else
      session[:partner_mode] = false
    end

    # In partner mode, do not hydrate @active_workspace from any prior customer workspace.
    if current_user.respond_to?(:partner?) && current_user.partner? && session[:partner_mode]
      @active_workspace = nil
      return
    end

    pending_invite = cookies.signed[:pending_invite_token].present?

    if session[:active_workspace_id].present?
      active_id = session[:active_workspace_id].to_i
      @active_workspace =
        available_workspaces
          .detect { |w| w.id.to_i == active_id }
    end

    @active_workspace ||= available_workspaces.first

    Rails.logger.info(
      "[WorkspaceContext] user_id=#{current_user.id} session_active_workspace_id=#{session[:active_workspace_id].inspect} resolved_active_workspace_id=#{@active_workspace&.id.inspect} path=#{request.path}"
    )

    if @active_workspace.present? && session[:active_workspace_id].blank?
      session[:active_workspace_id] = @active_workspace.id
      return
    end

    return if pending_invite

    if @active_workspace.nil?
      # Partners default to the partner dashboard; do NOT auto-create customer workspaces.
      return if current_user.respond_to?(:partner?) && current_user.partner?

      name = current_user.full_name.presence || "#{current_user.email}'s Workspace"

      @active_workspace = Workspace.create!(
        name:  name,
        owner: current_user
      )

      WorkspaceUser.create!(
        workspace: @active_workspace,
        user:      current_user,
        is_owner:  true,
        role:      "owner"
      )

      session[:active_workspace_id] = @active_workspace.id
    end
  end

  def redirect_partner_profile_to_partner_portal
    return unless current_user&.respond_to?(:partner?) && current_user.partner?

    # Only enforce partner-only restrictions when the user is explicitly in partner mode.
    # If they're on a customer workspace, /settings should behave like normal customer settings.
    return unless session[:partner_mode]

    if request.path.start_with?("/settings")
      # In partner mode, only Profile is allowed here.
      return redirect_to edit_partners_profile_path if request.path == "/settings/profile"
      return redirect_to partner_dashboard_path if request.path == "/settings/cookies"
      return redirect_to partner_dashboard_path
    end
  end

  def authenticate_admin
    unless current_user&.admin?
      flash[:alert] = "You are not authorized to access this page."
      redirect_to(root_path)
    end
  end

  def lucas_only
    return if devise_controller?
    # left intentionally permissive in dev
  end

  def set_layout_defaults
    @show_right_panel = false
  end

  # -------------------------
  # Demo workspace read-only mode
  # -------------------------
  def demo_workspace_active?
    return false unless current_user && @active_workspace

    dw = demo_workspace
    dw && @active_workspace.id == dw.id
  end

  def enforce_demo_read_only!
    return unless demo_workspace_active?

    # Allow safe reads.
    return if request.get? || request.head?

    # Allow exiting masquerade; this only mutates the session.
    return if controller_path == "admin/masquerades" && action_name == "destroy"

    # Allow switching away from demo (session-only mutation).
    return if controller_path == "workspaces" && action_name == "switch"

    # Allow AI chat to function in demo; it will be cleared nightly by demo:generate_daily.
    return if controller_path.start_with?("ai_chat/")

    msg = "Demo dashboard is read-only. Changes are disabled."

    # Many client actions use XHR/fetch but don't set format=json.
    # If we redirect here, the browser may follow the 302 and you won't get a clean toast.
    if request.xhr?
      return render json: { ok: false, error: "demo_read_only", message: msg }, status: :forbidden
    end

    respond_to do |format|
      format.json { render json: { ok: false, error: "demo_read_only", message: msg }, status: :forbidden }
      format.any do
        flash[:alert] = msg
        redirect_back(fallback_location: dashboard_path)
      end
    end
  end

  def set_unread_insights
    @unread_insights_count = 0
  end


  def show_right_panel
    @show_right_panel = true
    @version = "v26.040"
  end

  def set_logit_margin_threshold
    @logit_margin_threshold = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f
  end

  def teams_admin_consent_url
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

    state = ["admin_consent", "w#{@active_workspace.id}", "u#{current_user.id}"].join(":")

    params = {
      client_id:    client_id,
      redirect_uri: redirect_uri,
      state:        state,
      scope:        scopes
    }

    "https://login.microsoftonline.com/organizations/v2.0/adminconsent?#{params.to_query}"
  end

  # app/controllers/application_controller.rb
  def set_right_panel_flags
    @show_chat_panel    = false
    @show_analyze_panel = false

    return unless user_signed_in? && @active_workspace

    wid = @active_workspace.id

    integrations = Integration.where(workspace_id: wid)
    has_integrations = integrations.exists?

    max_days_analyzed = integrations.maximum(:days_analyzed).to_i
    any_analyze_complete = integrations.where(analyze_complete: true).exists?

    # Never show analyzer/chat panel states when workspace has no integrations yet.
    return unless has_integrations

    @show_chat_panel    = any_analyze_complete || max_days_analyzed >= 30
    @show_analyze_panel = !@show_chat_panel
  end


  def show_chat_panel?
    @show_chat_panel
  end

  def show_analyze_panel?
    @show_analyze_panel
  end

  def teams_admin_state_encryptor
    @teams_admin_state_encryptor ||= begin
      key_len = ActiveSupport::MessageEncryptor.key_len
      secret  = Rails.application.key_generator.generate_key("teams-admin-state", key_len)
      ActiveSupport::MessageEncryptor.new(secret)
    end
  end

  def encrypt_admin_state(workspace_id, user_id)
    payload = { w: workspace_id, u: user_id }.to_json
    teams_admin_state_encryptor.encrypt_and_sign(payload)
  end

  def decrypt_admin_state(token)
    json = teams_admin_state_encryptor.decrypt_and_verify(token)
    JSON.parse(json, symbolize_names: true)
  rescue => e
    Rails.logger.warn "[Teams OAuth] decrypt_admin_state failed: #{e.class} #{e.message}"
    nil
  end

  # -----------------------------
  # OAuth state helpers (shared)
  # -----------------------------

  def oauth_state_begin!(provider:, workspace_id:, internal_state: nil)
    raise "Must be signed in" unless current_user

    exp = (Time.current + OAUTH_STATE_TTL).to_i
    payload = {
      provider:       provider.to_s,
      workspace_id:   workspace_id,
      user_id:        current_user.id,
      internal_state: internal_state,
      exp:            exp
    }

    token = oauth_state_encryptor.encrypt_and_sign(payload.to_json)

    # Stateless OAuth state to avoid oversized cookie sessions
    token
  end

  def oauth_state_verify!(provider:, returned_state:)
    actual = returned_state.to_s

    payload = JSON.parse(oauth_state_encryptor.decrypt_and_verify(actual)) rescue nil
    raise "Missing oauth state" if payload.blank?

    exp = payload["exp"].to_i
    raise "Expired oauth state" if exp < Time.current.to_i

    if payload["user_id"].to_i != current_user.id
      raise "OAuth state user mismatch"
    end

    if payload["provider"].to_s != provider.to_s
      raise "OAuth state mismatch"
    end

    payload
  end

  def oauth_state_encryptor
    secret = Rails.application.secret_key_base
    salt   = "oauth_state_v1"
    key = ActiveSupport::KeyGenerator.new(secret).generate_key(salt, 32)
    ActiveSupport::MessageEncryptor.new(key)
  end

  # ----- INSIGHTS HELPERS -----
  def current_user_group_ids(workspace)
    iu_ids =
      current_user.integration_users
                  .joins(:integration)
                  .where(integrations: { workspace_id: workspace.id })
                  .pluck(:id)

    return [] if iu_ids.empty?

    Group.joins(:group_members)
         .where(workspace_id: workspace.id, group_members: { integration_user_id: iu_ids })
         .distinct
         .pluck(:id)
  end

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(
      :account_update,
      keys: [:first_name, :last_name, :email, :password, :password_confirmation]
    )
  end
end

