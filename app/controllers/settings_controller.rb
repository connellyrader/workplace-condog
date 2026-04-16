# app/controllers/settings_controller.rb
class SettingsController < ApplicationController
  WorkspaceDeleteBusy = Class.new(StandardError)
  skip_before_action :ensure_workspace_ready!, only: [:integrations, :destroy_workspace]

  # 🔒 Protect Settings by default (deny-by-default)
  # Integrations: allow non-admin users to connect their own tokens
  # Notifications: user-level settings allowed
  before_action :require_workspace_admin!,
                except: [:integrations, :disconnect_integration, :notifications, :update_notifications, :cookie_settings]


  before_action :require_workspace_owner!, only: [:destroy_workspace]


  def index
    @topbar_subtitle = "General"
  end

  def cookie_settings
    @topbar_subtitle = "Cookies"
    render :cookies
  end

  # ============================================================
  # Integrations (allowed for non-admins so they can connect tokens)
  # ============================================================
  def integrations
    @topbar_subtitle = "Integrations"

    @integrations = @active_workspace.integrations.order(:kind, :name)

    # 🔐 For MS Teams admin approval flow (intro page) – use encrypted admin state
    @teams_admin_state     = encrypt_admin_state(@active_workspace.id, current_user.id)
    @teams_admin_intro_url = teams_oauth_admin_intro_url(state: @teams_admin_state)

    @connected_integrations = @active_workspace.integrations

    connected_app_names =
      @connected_integrations.map { |i| i.kind.to_s.titleize }

    available_scope = App.where(status: "available")

    @available_integrations =
      if connected_app_names.any?
        available_scope.where.not(name: connected_app_names)
      else
        available_scope
      end
        .order(Arel.sql(<<~SQL.squish))
          CASE
            WHEN name = 'Slack' THEN 0
            WHEN name = 'Microsoft Teams' THEN 1
            ELSE 2
          END, name
        SQL

    @future_integrations = App.where(status: "future").order(:name)

    @apps_by_kind =
      App.all.each_with_object({}) do |app, map|
        key = app.name.to_s.parameterize.underscore
        map[key] = app
        short = key.split("_").last
        map[short] ||= app
      end

    # Workspace-level install URLs (Slack + Teams) for AVAILABLE apps
    @install_paths = {}
    @available_integrations.each do |app|
      @install_paths[app.name] =
        case app.name
        when "Slack"
          slack_history_start_path(state: build_integration_state("slack"))
        when "Microsoft Teams"
          teams_connect_path(state: build_integration_state("microsoft_teams"))
        else
          nil
        end
    end

    # ------------------------------------------------------------
    # Per-user connection state for already-installed integrations
    # ------------------------------------------------------------
    @user_connected_by_integration_id = {}
    @user_connect_path_by_integration_id = {}

    user_ius =
      current_user.integration_users
                  .joins(:integration)
                  .where(integrations: { workspace_id: @active_workspace.id })
                  .index_by(&:integration_id)

    @connected_integrations.each do |integration|
      iu = user_ius[integration.id]

      connected_for_user =
        case integration.kind.to_s
        when "slack"
          iu&.slack_history_token.present? || iu&.slack_refresh_token.present?
        when "microsoft_teams"
          iu&.ms_refresh_token.present?
        else
          true
        end

      @user_connected_by_integration_id[integration.id] = connected_for_user

      @user_connect_path_by_integration_id[integration.id] =
        case integration.kind.to_s
        when "slack"
          slack_history_start_path(state: build_integration_state("slack"))
        when "microsoft_teams"
          teams_connect_path(state: build_integration_state("microsoft_teams"))
        else
          nil
        end
    end
  end

  def disconnect_integration
    integration = @active_workspace.integrations.find(params[:id])
    iu = integration.integration_users.find_by(user_id: current_user.id)

    # If they never connected, treat as success (idempotent)
    unless iu
      respond_to do |format|
        format.html { redirect_to integrations_path, notice: "Connection removed." }
        format.json { render json: { ok: true } }
      end
      return
    end

    case integration.kind.to_s
    when "slack"
      iu.update!(
        slack_history_token:    nil,
        slack_refresh_token:    nil,
        slack_bot_token:        nil,
        slack_token_expires_at: nil
      )
    when "microsoft_teams"
      iu.update!(
        ms_access_token:  nil,
        ms_refresh_token: nil,
        ms_expires_at:    nil
      )
    else
      # no-op for future integrations
    end

    respond_to do |format|
      format.html { redirect_to integrations_path, notice: "Connection removed." }
      format.json { render json: { ok: true } }
    end
  rescue ActiveRecord::RecordNotFound
    respond_to do |format|
      format.html { redirect_to integrations_path, alert: "Integration not found." }
      format.json { render json: { ok: false, error: "not_found" }, status: :not_found }
    end
  rescue => e
    Rails.logger.warn("[Settings#disconnect_integration] failed: #{e.class}: #{e.message}")
    respond_to do |format|
      format.html { redirect_to integrations_path, alert: "Unable to remove connection. Please try again." }
      format.json { render json: { ok: false, error: "disconnect_failed" }, status: :unprocessable_entity }
    end
  end

  # ============================================================
  # Groups (seat-affecting)
  # ============================================================
  def groups
    @topbar_subtitle = "Groups"

    @groups = @active_workspace.groups.includes(:integration_users).order("name ASC")

    assigned_ids =
      GroupMember
        .joins(:group)
        .where(groups: { workspace_id: @active_workspace.id })
        .distinct
        .pluck(:integration_user_id)

    base_unassigned =
      @active_workspace.integration_users
        .humans
        .where(active: true)

    @unassigned_scope =
      if assigned_ids.any?
        base_unassigned.where.not(id: assigned_ids)
      else
        base_unassigned
      end

    @unassigned_total   = @unassigned_scope.count
    @unassigned_preview = @unassigned_scope.limit(3)
    @unassigned_ids     = @unassigned_scope.pluck(:id)

    modal_scope =
      @active_workspace.integration_users
        .humans
        .where(active: true)
        .distinct

    @modal_users           = modal_scope.order("integration_users.real_name ASC")
    @modal_ungrouped_total = @modal_users.size
  end

  def group
    @group = @active_workspace.groups.find(params[:id])
    @topbar_subtitle = @group.name

    @members =
      @group.integration_users
            .humans
            .where(active: true)
            .includes(:integration)
            .order("integration_users.real_name ASC")

    @all_members =
      @active_workspace.integration_users
        .humans
        .where(active: true)
        .distinct
        .order("integration_users.real_name ASC")

    @group_member_ids = @group.integration_users.pluck(:id)

    @workspace_users_by_user_id =
      @active_workspace.workspace_users.index_by(&:user_id)

    first_group = @active_workspace.groups.order(:created_at).first
    @is_everyone_group =
      first_group.present? &&
      first_group.id == @group.id &&
      @group.name == "Everyone"
  end

  def group_users
    query = params[:q].to_s.strip

    base_scope =
      @active_workspace.integration_users
        .humans
        .where(active: true)
        .distinct

    base_scope =
      if query.present?
        base_scope.where(
          "integration_users.real_name ILIKE :q OR integration_users.email ILIKE :q",
          q: "%#{query}%"
        )
      else
        base_scope
      end

    @ungrouped_users = base_scope.order("integration_users.real_name ASC")

    render partial: "settings/group_users",
           locals: { ungrouped_users: @ungrouped_users, search_query: query }
  end

  def create_group
    name      = params.dig(:group, :name).to_s.strip
    ids_param = params.dig(:group, :user_ids).to_s

    integration_user_ids =
      ids_param.split(",").map(&:strip).reject(&:blank?).map(&:to_i).uniq

    if name.blank?
      redirect_to groups_path, alert: "Please enter a group name."
      return
    end

    integration_users =
      @active_workspace.integration_users
        .humans
        .where(active: true, id: integration_user_ids)

    group = nil

    Group.transaction do
      group = @active_workspace.groups.create!(name: name)

      integration_users.each do |iu|
        GroupMember.find_or_create_by!(group: group, integration_user: iu)
      end

      everyone_group =
        @active_workspace.groups
                         .order(:created_at)
                         .find_by(name: "Everyone")

      if everyone_group && everyone_group.id != group.id
        integration_users.each do |iu|
          GroupMember.find_or_create_by!(group: everyone_group, integration_user: iu)
        end
      end
    end

    # ✅ seat-affecting: group members changed
    queue_stripe_qty_sync!

    redirect_to settings_group_path(group),
                notice: "Group “#{group.name}” created with #{integration_users.size} member#{'s' unless integration_users.size == 1}."
  end

  def update_group
    group     = @active_workspace.groups.find(params[:id])
    name      = params.dig(:group, :name).to_s.strip
    ids_param = params.dig(:group, :user_ids).to_s

    integration_user_ids =
      ids_param.split(",").map(&:strip).reject(&:blank?).map(&:to_i).uniq

    everyone_group =
      @active_workspace.groups
                       .order(:created_at)
                       .find_by(name: "Everyone")

    is_everyone =
      everyone_group.present? &&
      everyone_group.id == group.id

    if !is_everyone && name.blank?
      redirect_to settings_group_path(group), alert: "Please enter a group name."
      return
    end

    integration_users =
      @active_workspace.integration_users
        .humans
        .where(active: true, id: integration_user_ids)

    Group.transaction do
      group.update!(name: name) unless is_everyone

      current_ids   = group.integration_users.pluck(:id)
      desired_ids   = integration_users.pluck(:id)
      ids_to_add    = desired_ids - current_ids
      ids_to_remove = current_ids - desired_ids

      # Remove from this group (delete_all bypasses callbacks)
      GroupMember.where(group: group, integration_user_id: ids_to_remove).delete_all

      # If removing from Everyone, also remove from all other groups in this workspace
      if is_everyone && ids_to_remove.any?
        GroupMember.joins(:group)
                   .where(
                     groups: { workspace_id: @active_workspace.id },
                     integration_user_id: ids_to_remove
                   )
                   .delete_all
      end

      ids_to_add.each do |iu_id|
        GroupMember.find_or_create_by!(group: group, integration_user_id: iu_id)
      end

      if everyone_group && !is_everyone && ids_to_add.any?
        ids_to_add.each do |iu_id|
          GroupMember.find_or_create_by!(group: everyone_group, integration_user_id: iu_id)
        end
      end
    end

    # ✅ seat-affecting: group members changed (and delete_all bypasses callbacks)
    queue_stripe_qty_sync!

    removed_note =
      if is_everyone
        " Users removed from Everyone were also removed from all other groups."
      else
        ""
      end

    redirect_to settings_group_path(group),
                notice: "Group “#{group.name}” updated with #{integration_users.size} member#{'s' unless integration_users.size == 1}.#{removed_note}"
  end

  def remove_group_member
    group = @active_workspace.groups.find(params[:id])

    iu = group.integration_users.find_by(id: params[:integration_user_id])
    unless iu
      render json: { ok: false, error: "Member not found in this group." }, status: :not_found
      return
    end

    GroupMember.where(group: group, integration_user_id: iu.id).delete_all

    # ✅ seat-affecting
    queue_stripe_qty_sync!

    render json: { ok: true, message: "Member removed from group." }
  end

  def destroy_group
    group = @active_workspace.groups.find(params[:id])

    Group.transaction do
      GroupMember.where(group: group).delete_all
      group.destroy!
    end

    # ✅ seat-affecting
    queue_stripe_qty_sync!

    render json: { ok: true, message: "Group deleted." }
  end

  # ============================================================
  # Manage Users
  # ============================================================
  def manage_users
    @current_workspace_user = @active_workspace.workspace_users.find_by(user: current_user)
    @current_role           = @current_workspace_user&.role || "viewer"

    @people = @active_workspace.workspace_users
               .includes(user: { integration_users: :integration })
               .order("users.first_name ASC")
               .page(params[:page])
               .per(50)

    @pending_invites =
      @active_workspace.workspace_invites
        .where(status: "pending")
        .includes(:integration_user)
        .order(name: :asc)

    invited_ids =
      @pending_invites.map(&:integration_user_id).compact.uniq

    base_modal_invitable =
      @active_workspace.integration_users
        .humans
        .without_workspace_account_for(@active_workspace)
        .where(active: true)
        .distinct

    base_modal_invitable =
      if invited_ids.any?
        base_modal_invitable.where.not(id: invited_ids)
      else
        base_modal_invitable
      end

    @modal_invitable_users =
      base_modal_invitable.order("integration_users.real_name ASC")

    @modal_invitable_total = @modal_invitable_users.size

    group_invitable =
      @active_workspace.integration_users
        .humans
        .without_workspace_account_for(@active_workspace)
        .where(active: true)
        .joins(:groups)
        .where(groups: { workspace_id: @active_workspace.id })
        .distinct

    @invitable_total   = group_invitable.count
    @invitable_preview =
      group_invitable
        .where.not(avatar_url: [nil, ""])
        .limit(3)

    member_rows =
      @people.map do |wu|
        user = wu.user
        next unless user

        name = user.full_name.to_s
        {
          kind:           :member,
          sort_name:      name.downcase,
          workspace_user: wu,
          user:           user
        }
      end.compact

    invite_rows =
      @pending_invites.map do |invite|
        iu   = invite.integration_user
        name = invite.name.presence || iu&.real_name.presence || invite.email

        {
          kind:             :invite,
          sort_name:        name.to_s.downcase,
          invite:           invite,
          integration_user: iu
        }
      end

    @rows_for_manage_users = (member_rows + invite_rows).sort_by { |row| row[:sort_name] }
  end

  def invite_users
    query = params[:q].to_s.strip

    invited_ids =
      @active_workspace.workspace_invites
        .where(status: "pending")
        .pluck(:integration_user_id)
        .compact
        .uniq

    base_invitable =
      @active_workspace.integration_users
        .humans
        .without_workspace_account_for(@active_workspace)
        .where(active: true)
        .distinct

    base_invitable =
      if invited_ids.any?
        base_invitable.where.not(id: invited_ids)
      else
        base_invitable
      end

    @invitable_users =
      if query.present?
        base_invitable.where(
          "integration_users.real_name ILIKE :q OR integration_users.email ILIKE :q",
          q: "%#{query}%"
        )
      else
        base_invitable
      end

    @invitable_users =
      @invitable_users.order("integration_users.real_name ASC")

    render partial: "settings/invite_users",
           locals: { invitable_users: @invitable_users, search_query: query }
  end

  def send_invites
    ids_param = params.dig(:invite, :integration_user_ids).to_s
    integration_user_ids =
      ids_param.split(",").map(&:strip).reject(&:blank?).map(&:to_i).uniq

    if integration_user_ids.empty?
      redirect_to manage_users_path, alert: "No people selected to invite."
      return
    end

    integration_users =
      @active_workspace.integration_users
        .humans
        .without_workspace_account_for(@active_workspace)
        .where(active: true, id: integration_user_ids)

    created_count = 0

    WorkspaceInvite.transaction do
      integration_users.each do |iu|
        invite = @active_workspace.workspace_invites.find_by(integration_user: iu)

        if invite.present?
          case invite.status
          when "pending", "accepted"
            next
          else
            invite.email      = iu.email
            invite.name       = iu.real_name
            invite.invited_by = current_user
            invite.role       = invite.role.presence || "user"
            invite.status     = "pending"
            invite.expires_at = 14.days.from_now

            raw = WorkspaceInvite.generate_token
            invite.raw_token    = raw
            invite.token_digest = WorkspaceInvite.digest_token(raw)

            invite.queue_invite_delivery!(raw)
            invite.save!
            created_count += 1
          end
        else
          invite = @active_workspace.workspace_invites.new(
            workspace:        @active_workspace,
            integration_user: iu,
            email:            iu.email,
            name:             iu.real_name,
            invited_by:       current_user,
            role:             "user",
            status:           "pending",
            expires_at:       14.days.from_now
          )

          raw = WorkspaceInvite.generate_token
          invite.raw_token = raw

          invite.queue_invite_delivery!(raw)
          invite.save!
          created_count += 1
        end
      end
    end

    if created_count.zero?
      redirect_to manage_users_path,
                  alert: "No new invites created. Everyone you selected already has a pending invite or an account."
    else
      redirect_to manage_users_path,
                  notice: "#{created_count} invite#{'s' unless created_count == 1} created or re-sent."
    end
  end

  def update_member_role
    role = params[:role].to_s

    unless %w[user viewer admin].include?(role)
      render json: { ok: false, error: "Invalid role." }, status: :unprocessable_entity
      return
    end

    label =
      case role
      when "admin"  then "Admin"
      when "viewer" then "Viewer"
      else               "User"
      end

    if params[:user_id].present?
      wu = @active_workspace.workspace_users.find_by(user_id: params[:user_id])
      unless wu
        render json: { ok: false, error: "User not found in workspace." }, status: :not_found
        return
      end

      if wu.is_owner?
        render json: { ok: false, error: "Cannot change the role of the workspace owner." }, status: :forbidden
        return
      end

      wu.update!(role: role)

      render json: { ok: true, kind: "user", role: role, role_label: label }
    elsif params[:invite_id].present?
      invite = @active_workspace.workspace_invites.find_by(id: params[:invite_id], status: "pending")
      unless invite
        render json: { ok: false, error: "Invite not found." }, status: :not_found
        return
      end

      invite.update!(role: role)

      render json: { ok: true, kind: "invite", role: role, role_label: label }
    else
      render json: { ok: false, error: "No target specified." }, status: :unprocessable_entity
    end
  end

  def remove_member
    if params[:invite_id].present?
      invite = @active_workspace.workspace_invites.find_by(id: params[:invite_id], status: "pending")
      unless invite
        render json: { ok: false, error: "Invite not found." }, status: :not_found
        return
      end

      invite.update!(status: "canceled")
      render json: { ok: true, kind: "invite", message: "Invite canceled." }

    elsif params[:user_id].present?
      wu = @active_workspace.workspace_users.find_by(workspace: @active_workspace, user_id: params[:user_id])
      unless wu
        render json: { ok: false, error: "User not found in workspace." }, status: :not_found
        return
      end

      if wu.is_owner?
        render json: { ok: false, error: "Cannot remove the workspace owner." }, status: :forbidden
        return
      end

      if wu.user_id == current_user.id
        render json: { ok: false, error: "You cannot remove yourself." }, status: :forbidden
        return
      end

      wu.destroy!

      # Seat-affecting (WorkspaceUser callback also enqueues, but this is harmless/cheap due to debounce)
      queue_stripe_qty_sync!

      render json: { ok: true, kind: "user", message: "User removed from workspace." }
    else
      render json: { ok: false, error: "No target specified." }, status: :unprocessable_entity
    end
  end

  # ============================================================
  # Notifications (allowed for non-admins)
  # ============================================================
  def notifications
    @topbar_subtitle = "Notifications"
    build_notification_settings_payload

    respond_to do |format|
      format.html
      format.json { render json: notification_payload_json }
    end
  end

  def update_notifications
    preference    = notification_preference_for_current_user
    account_type  = notification_account_type_for(current_user)
    permission    = workspace_permission_for(account_type)
    allowed_types = permission.enabled? ? permission.allowed_types : []

    key   = params[:key].to_s
    value = params[:value]

    if NotificationPreference::CHANNEL_KEYS.include?(key)
      unless channel_available?(key)
        render json: { error: "Channel unavailable" }, status: :unprocessable_entity
        return
      end

      preference.update_flag!(key, value)
    elsif NotificationPreference::TYPE_KEYS.include?(key)
      unless allowed_types.include?(key)
        render json: { error: "Not allowed for this role" }, status: :forbidden
        return
      end

      preference.update_flag!(key, value)

      if key == "all_group_insights" && ActiveModel::Type::Boolean.new.cast(value)
        if allowed_types.include?("my_group_insights")
          preference.update_flag!("my_group_insights", true)
        end
      end
    else
      render json: { error: "Unknown setting" }, status: :unprocessable_entity
      return
    end

    render json: {
      status: "ok",
      channels: channel_settings_for(preference),
      types: type_settings_for(preference, allowed_types)
    }
  end

  def update_notification_permissions
    unless workspace_owner_or_admin?
      render json: { error: "forbidden" }, status: :forbidden
      return
    end

    account_type = params[:account_type].to_s
    unless WorkspaceNotificationPermission::ACCOUNT_TYPES.include?(account_type)
      render json: { error: "invalid account type" }, status: :unprocessable_entity
      return
    end

    permission = WorkspaceNotificationPermission.find_or_initialize_by(
      workspace: @active_workspace,
      account_type: account_type
    )

    if params.key?(:enabled)
      permission.enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
    end

    if params.key?(:allowed_types)
      permission.allowed_types = Array(params[:allowed_types])
    end

    permission.save!

    render json: {
      status: "ok",
      permission: {
        account_type: permission.account_type,
        enabled: permission.enabled?,
        allowed_types: permission.allowed_types
      }
    }
  end

  # ============================================================
  # Billing (admin-only)
  # ============================================================
  def billing
    @topbar_subtitle = "Billing"
    ws = @active_workspace

    if ws.stripe_customer_id.blank?
      customer = Stripe::Customer.create(
        email:    current_user.email,
        name:     current_user.respond_to?(:full_name) ? current_user.full_name : nil,
        metadata: { app_user_id: current_user.id, workspace_id: ws.id }
      )
      ws.update!(stripe_customer_id: customer.id)
    end

    @stripe_customer_id = ws.stripe_customer_id

    @subscription_record =
      ws.subscriptions
        .order(created_at: :desc)
        .find_by(status: %w[active trialing past_due unpaid incomplete canceled]) ||
      ws.subscriptions.order(created_at: :desc).first

    @stripe_subscription = nil
    @subscription_item   = nil
    @stripe_price        = nil
    @stripe_product      = nil

    @upcoming_invoice      = nil
    @upcoming_amount_cents = nil
    @resume_headline_amount_cents = nil

    if @subscription_record&.stripe_subscription_id.present?
      begin
        @stripe_subscription = Stripe::Subscription.retrieve(
          {
            id: @subscription_record.stripe_subscription_id,
            expand: [
              "items.data.price.product",
              "latest_invoice",
              "latest_invoice.payment_intent"
            ]
          }
        )

        @subscription_item = @stripe_subscription.items.data.first
        @stripe_price      = @subscription_item&.price
        @stripe_product    = @stripe_price&.product

        begin
          preview = Stripe::APIResource.send(
            :request_stripe_object,
            method: :post,
            path: "/v1/invoices/create_preview",
            params: { customer: @stripe_customer_id, subscription: @stripe_subscription.id },
            opts: {}
          )
          @upcoming_invoice      = preview
          @upcoming_amount_cents = (preview["total"] || preview["amount_due"]).to_i
        rescue => e
          Rails.logger.warn("[Billing] create_preview (next invoice) failed: #{e.class}: #{e.message}")
        end
      rescue Stripe::StripeError => e
        Rails.logger.warn("[Billing] Stripe subscription retrieve failed: #{e.class}: #{e.message}")
        @stripe_subscription = nil
      end
    end

    @stripe_customer = Stripe::Customer.retrieve(
      { id: @stripe_customer_id, expand: ["invoice_settings.default_payment_method"] }
    )

    default_pm = @stripe_customer.invoice_settings&.default_payment_method
    @default_payment_method_id =
      if default_pm.respond_to?(:id)
        default_pm.id
      else
        default_pm.to_s.presence
      end

      card_list = Stripe::PaymentMethod.list(customer: @stripe_customer_id, type: "card")
      bank_list = Stripe::PaymentMethod.list(customer: @stripe_customer_id, type: "us_bank_account")

      @card_payment_methods = Array(card_list.data)
      @bank_payment_methods = Array(bank_list.data)
      @payment_methods = (@card_payment_methods + @bank_payment_methods)

    inv_list = Stripe::Invoice.list(customer: @stripe_customer_id, limit: 50)
    @invoices = Array(inv_list.data)
                 .reject { |inv| inv["status"].to_s == "draft" }
                 .first(20)

    begin
      open_list = Stripe::Invoice.list(customer: @stripe_customer_id, status: "open", limit: 1)
      @open_invoice = Array(open_list.data).first
    rescue => e
      Rails.logger.warn("[Billing] open invoice lookup failed: #{e.class}: #{e.message}")
      @open_invoice = nil
    end

    @manual_invoice_due_at = nil
    @manual_invoice_due_label = nil
    @manual_invoice_notice = false

    collection_method = @stripe_subscription&.[]("collection_method").to_s
    is_manual_invoicing = (collection_method == "send_invoice")

    if is_manual_invoicing && @open_invoice.present?
      due_unix =
        if @open_invoice.respond_to?(:due_date)
          @open_invoice.due_date
        else
          @open_invoice["due_date"]
        end

      due_unix = due_unix.to_i

      if due_unix.positive?
        @manual_invoice_due_at = Time.at(due_unix).in_time_zone
        @manual_invoice_due_label = @manual_invoice_due_at.strftime("%b %-d, %Y")
      end
    end

    delinquent_from_status =
      @stripe_subscription.present? && %w[past_due unpaid].include?(@stripe_subscription["status"].to_s)

    delinquent_from_invoice =
      if @open_invoice.present?
        if is_manual_invoicing
          due_unix =
            if @open_invoice.respond_to?(:due_date)
              @open_invoice.due_date
            else
              @open_invoice["due_date"]
            end

          due_unix = due_unix.to_i
          due_unix.positive? && due_unix < Time.current.to_i
        else
          true
        end
      else
        false
      end

    @is_delinquent = delinquent_from_status || delinquent_from_invoice
    @manual_invoice_notice = is_manual_invoicing && @open_invoice.present? && !@is_delinquent

    # ✅ Seat count: single source of truth on Workspace (dedupes group members vs account holders)
    @resume_seat_count = ws.billable_seat_count

    # Manual invoicing eligibility (Net terms)
    @manual_invoice_min_seats = OnboardingController::MANUAL_INVOICE_MIN_SEATS
    @manual_invoice_eligible  = @resume_seat_count.to_i >= @manual_invoice_min_seats

    begin
      price_id_for_resume =
        if @stripe_price&.respond_to?(:id) && @stripe_price.id.present?
          @stripe_price.id
        else
          "price_1RQWKcGfpLtyy7R52c0tJ2dv"
        end

      preview_new = Stripe::APIResource.send(
        :request_stripe_object,
        method: :post,
        path: "/v1/invoices/create_preview",
        params: {
          customer: @stripe_customer_id,
          preview_mode: "recurring",
          subscription_details: {
            items: [{ price: price_id_for_resume, quantity: @resume_seat_count.to_i }]
          }
        },
        opts: {}
      )

      @resume_headline_amount_cents = (preview_new["total"] || preview_new["amount_due"]).to_i
    rescue => e
      Rails.logger.warn("[Billing] create_preview recurring (resume/new) failed: #{e.class}: #{e.message}")
      @resume_headline_amount_cents = nil
    end

    setup_intent = Stripe::SetupIntent.create(
      customer: @stripe_customer_id,
      payment_method_types: ["card", "us_bank_account"],
      payment_method_options: {
        us_bank_account: {
          verification_method: "instant"
        }
      }
    )
    @setup_intent_client_secret = setup_intent.client_secret
    @setup_intent_id            = setup_intent.id
  end

  def billing_add_card
    ws = @active_workspace
    customer_id = ws.stripe_customer_id
    pm_id = params[:payment_method].to_s

    render json: { ok: false, error: "missing_payment_method" }, status: :unprocessable_entity and return if pm_id.blank?

    Stripe::PaymentMethod.attach(pm_id, { customer: customer_id })

    set_default = params.key?(:set_default) ? ActiveModel::Type::Boolean.new.cast(params[:set_default]) : true
    Stripe::Customer.update(customer_id, { invoice_settings: { default_payment_method: pm_id } }) if set_default

    render json: { ok: true }
  rescue Stripe::StripeError => e
    Rails.logger.warn("[Billing] add_card failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "stripe_error", message: e.message }, status: :unprocessable_entity
  end

  def billing_set_default_card
    ws = @active_workspace
    customer_id = ws.stripe_customer_id
    pm_id = params[:payment_method_id].to_s

    render json: { ok: false, error: "missing_payment_method" }, status: :unprocessable_entity and return if pm_id.blank?

    Stripe::Customer.update(customer_id, { invoice_settings: { default_payment_method: pm_id } })
    render json: { ok: true }
  rescue Stripe::StripeError => e
    Rails.logger.warn("[Billing] set_default_card failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "stripe_error", message: e.message }, status: :unprocessable_entity
  end

  def billing_delete_card
    ws = @active_workspace
    customer_id = ws.stripe_customer_id
    pm_id = params[:payment_method_id].to_s

    render json: { ok: false, error: "missing_payment_method" }, status: :unprocessable_entity and return if pm_id.blank?

    Stripe::PaymentMethod.detach(pm_id)

    customer = Stripe::Customer.retrieve(customer_id)

    default_pm = customer.invoice_settings&.default_payment_method
    current_default_id =
      if default_pm.respond_to?(:id)
        default_pm.id
      else
        default_pm.to_s.presence
      end

    if current_default_id.to_s == pm_id.to_s
      Stripe::Customer.update(customer_id, { invoice_settings: { default_payment_method: nil } })
    end

    render json: { ok: true }
  rescue Stripe::StripeError => e
    Rails.logger.warn("[Billing] delete_card failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "stripe_error", message: e.message }, status: :unprocessable_entity
  end

  def billing_cancel_subscription
    ws = @active_workspace
    sub = ws.subscriptions.order(created_at: :desc).find_by(status: %w[active trialing past_due unpaid incomplete])
    render json: { ok: false, error: "no_subscription" }, status: :not_found and return unless sub&.stripe_subscription_id.present?

    stripe_sub = Stripe::Subscription.update(sub.stripe_subscription_id, { cancel_at_period_end: true })
    sub.update!(status: stripe_sub["status"].to_s) if sub.respond_to?(:status)

    render json: { ok: true, cancel_at_period_end: stripe_sub.cancel_at_period_end }
  rescue Stripe::StripeError => e
    Rails.logger.warn("[Billing] cancel_subscription failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "stripe_error", message: e.message }, status: :unprocessable_entity
  end

  def billing_pay_now
    ws = @active_workspace
    customer_id = ws.stripe_customer_id

    invoices = Stripe::Invoice.list(customer: customer_id, status: "open", limit: 1).data
    inv = invoices.first
    render json: { ok: false, error: "no_open_invoice" }, status: :not_found and return unless inv

    paid = Stripe::Invoice.pay(inv.id)
    Notifiers::ReceiptSender.send_for_invoice(workspace: ws, invoice: paid)
    render json: { ok: true, invoice_id: paid.id, status: paid.status }
  rescue Stripe::StripeError => e
    Rails.logger.warn("[Billing] pay_now failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "stripe_error", message: e.message }, status: :unprocessable_entity
  end

  def billing_switch_to_net30
    ws = @active_workspace
    customer_id = ws.stripe_customer_id
    render json: { ok: false, error: "missing_customer" }, status: :unprocessable_entity and return if customer_id.blank?

    seat_count = ws.billable_seat_count.to_i
    min_seats  = OnboardingController::MANUAL_INVOICE_MIN_SEATS
    due_days   = OnboardingController::MANUAL_INVOICE_DAYS_UNTIL_DUE

    if seat_count < min_seats
      return render json: {
        ok: false,
        error: "net30_not_eligible",
        message: "Net #{due_days} invoicing requires at least #{min_seats} seats."
      }, status: :unprocessable_entity
    end

    # Don't allow switching while an open invoice exists (keeps the story clean)
    begin
      open_inv = Stripe::Invoice.list(customer: customer_id, status: "open", limit: 1).data.first
      if open_inv
        return render json: { ok: false, error: "invoice_open" }, status: :unprocessable_entity
      end
    rescue => e
      Rails.logger.warn("[Billing] open invoice lookup failed (switch_to_net30): #{e.class}: #{e.message}")
    end

    sub_rec =
      ws.subscriptions
        .order(created_at: :desc)
        .find_by(status: %w[active trialing past_due unpaid incomplete]) ||
      ws.subscriptions.order(created_at: :desc).first

    render json: { ok: false, error: "no_subscription" }, status: :not_found and return unless sub_rec&.stripe_subscription_id.present?

    stripe_sub = Stripe::Subscription.retrieve({ id: sub_rec.stripe_subscription_id, expand: ["items.data"] })

    status = stripe_sub["status"].to_s
    if %w[canceled incomplete_expired].include?(status)
      return render json: { ok: false, error: "no_active_subscription" }, status: :unprocessable_entity
    end

    if !!stripe_sub["cancel_at_period_end"]
      return render json: { ok: false, error: "canceling" }, status: :unprocessable_entity
    end

    if stripe_sub["collection_method"].to_s == "send_invoice"
      return render json: { ok: false, error: "already_net30" }, status: :unprocessable_entity
    end

    # Update collection method now; it affects the NEXT invoice. Current period remains paid/autopay.
    Stripe::Subscription.update(
      stripe_sub.id,
      {
        collection_method: "send_invoice",
        days_until_due: due_days
      }
    )

    render json: { ok: true }
  rescue Stripe::StripeError => e
    Rails.logger.warn("[Billing] switch_to_net30 failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "stripe_error", message: e.message }, status: :unprocessable_entity
  end

  def billing_resume_subscription
    ws = @active_workspace
    customer_id = ws.stripe_customer_id
    render json: { ok: false, error: "missing_customer" }, status: :unprocessable_entity and return if customer_id.blank?

    desired_qty = ws.billable_seat_count
    price_id    = "price_1RQWKcGfpLtyy7R52c0tJ2dv"

    sub_rec =
      ws.subscriptions
        .order(created_at: :desc)
        .find_by(status: %w[active trialing past_due unpaid incomplete canceled]) ||
      ws.subscriptions.order(created_at: :desc).first

    stripe_sub_id = sub_rec&.stripe_subscription_id

    last_collection_method = nil
    last_days_until_due = nil

    if stripe_sub_id.present?
      stripe_sub = Stripe::Subscription.retrieve({ id: stripe_sub_id, expand: ["items.data"] })

      status    = stripe_sub["status"].to_s
      canceling = !!stripe_sub["cancel_at_period_end"]

      last_collection_method = stripe_sub["collection_method"].to_s
      last_days_until_due = stripe_sub["days_until_due"].to_i

      if canceling && %w[active trialing].include?(status)
        Stripe::Subscription.update(stripe_sub_id, cancel_at_period_end: false)
      end

      if %w[active trialing].include?(status)
        item = stripe_sub.items.data.first
        if item && item.quantity.to_i != desired_qty
          Stripe::SubscriptionItem.update(
            item.id,
            { quantity: desired_qty },
            { proration_behavior: "none" }
          )
        end

        return render json: { ok: true, mode: "updated_existing", desired_qty: desired_qty }
      end
    end

    manual_resume = (last_collection_method == "send_invoice")

    customer = Stripe::Customer.retrieve({ id: customer_id, expand: ["invoice_settings.default_payment_method"] })
    default_pm = customer.invoice_settings&.default_payment_method
    default_pm_id = default_pm.respond_to?(:id) ? default_pm.id : default_pm.to_s.presence

    if !manual_resume
      render json: { ok: false, error: "missing_default_payment_method" }, status: :unprocessable_entity and return if default_pm_id.blank?
    end

    new_sub_params = {
      customer: customer_id,
      items: [{ price: price_id, quantity: desired_qty }],
      proration_behavior: "none",
      payment_behavior: "default_incomplete",
      expand: ["latest_invoice", "latest_invoice.payment_intent"]
    }

    if manual_resume
      new_sub_params[:collection_method] = "send_invoice"
      new_sub_params[:days_until_due] = last_days_until_due.positive? ? last_days_until_due : 30
    else
      new_sub_params[:default_payment_method] = default_pm_id
      new_sub_params[:collection_method] = "charge_automatically"
    end

    new_sub = Stripe::Subscription.create(new_sub_params)

    begin
      ws.subscriptions.create!(
        user: current_user,
        workspace: ws,
        stripe_subscription_id: new_sub["id"].to_s,
        status: new_sub["status"].to_s,
        started_on: Date.today,
        expires_on: nil,
        amount: 0,
        interval: "month"
      )
    rescue => e
      Rails.logger.warn("[Billing] local subscription create failed: #{e.class}: #{e.message}")
    end

    invoice    = new_sub["latest_invoice"]
    invoice_id = invoice.respond_to?(:[]) ? invoice["id"].to_s : nil
    inv_status = invoice.respond_to?(:[]) ? invoice["status"].to_s : nil

    if invoice_id.blank?
      return render json: {
        ok: false,
        error: "invoice_missing",
        message: "Subscription created, but no invoice was generated."
      }, status: :unprocessable_entity
    end

    begin
      if inv_status == "draft"
        if Stripe::Invoice.respond_to?(:finalize_invoice)
          Stripe::Invoice.finalize_invoice(invoice_id)
        else
          Stripe::APIResource.send(
            :request_stripe_object,
            method: :post,
            path: "/v1/invoices/#{invoice_id}/finalize",
            params: {},
            opts: {}
          )
        end
      end

      paid_invoice =
        if Stripe::Invoice.respond_to?(:pay)
          Stripe::Invoice.pay(invoice_id)
        else
          Stripe::APIResource.send(
            :request_stripe_object,
            method: :post,
            path: "/v1/invoices/#{invoice_id}/pay",
            params: {},
            opts: {}
          )
        end

      paid_status = paid_invoice.respond_to?(:[]) ? paid_invoice["status"].to_s : ""

      if paid_status == "paid"
        Notifiers::ReceiptSender.send_for_invoice(workspace: ws, invoice: paid_invoice)
        return render json: {
          ok: true,
          mode: "created_new_and_charged",
          desired_qty: desired_qty,
          invoice_id: invoice_id
        }
      end
    rescue Stripe::StripeError => e
      Rails.logger.warn("[Billing] immediate invoice.pay failed: #{e.class}: #{e.message}")
    rescue => e
      Rails.logger.warn("[Billing] immediate invoice.pay failed: #{e.class}: #{e.message}")
    end

    begin
      refreshed =
        if Stripe::Invoice.respond_to?(:retrieve)
          Stripe::Invoice.retrieve(invoice_id)
        else
          Stripe::APIResource.send(
            :request_stripe_object,
            method: :get,
            path: "/v1/invoices/#{invoice_id}",
            params: {},
            opts: {}
          )
        end

      inv_status = refreshed.respond_to?(:[]) ? refreshed["status"].to_s : inv_status
      pi = refreshed.respond_to?(:[]) ? refreshed["payment_intent"] : nil
      pi_status = pi.respond_to?(:[]) ? pi["status"].to_s : nil
    rescue => e
      pi_status = nil
    end

    render json: {
      ok: false,
      error: "invoice_open",
      invoice_id: invoice_id,
      invoice_status: inv_status,
      payment_intent_status: pi_status,
      message: "We created an invoice but couldn’t charge it automatically. Use Pay Now to complete payment."
    }, status: :unprocessable_entity
  rescue Stripe::StripeError => e
    Rails.logger.warn("[Billing] resume_subscription failed: #{e.class}: #{e.message}")
    render json: { ok: false, error: "stripe_error", message: e.message }, status: :unprocessable_entity
  end

  # ============================================================
  # Workspace updates (admin-only)
  # ============================================================
  def update_workspace_icon
    file = params.dig(:workspace, :icon)

    if file.blank?
      render json: { ok: false, error: "No file selected." }, status: :unprocessable_entity
      return
    end

    unless file.content_type.to_s.start_with?("image/")
      render json: { ok: false, error: "Please upload an image file." }, status: :unprocessable_entity
      return
    end

    if file.size.to_i > 10.megabytes
      render json: { ok: false, error: "Icon must be 10MB or smaller." }, status: :unprocessable_entity
      return
    end

    old_attachment = @active_workspace.icon.attachment
    @active_workspace.icon.attach(file)
    old_attachment&.purge_later

    render json: {
      ok: true,
      message: "Workspace icon saved.",
      icon_url: url_for(@active_workspace.icon)
    }
  rescue ActiveStorage::IntegrityError, ActiveStorage::UnrepresentableError
    render json: { ok: false, error: "That image could not be processed." }, status: :unprocessable_entity
  rescue MiniMagick::Error, MiniMagick::Invalid, Vips::Error
    render json: { ok: false, error: "That image could not be processed." }, status: :unprocessable_entity
  end

  def update_workspace
    name = params.dig(:workspace, :name).to_s.strip

    if name.blank?
      render json: { ok: false, error: "Workspace name cannot be blank." }, status: :unprocessable_entity
      return
    end

    @active_workspace.name = name

    if @active_workspace.save
      render json: { ok: true, message: "Workspace name updated.", name: @active_workspace.name }
    else
      render json: { ok: false, error: @active_workspace.errors.full_messages.first || "Invalid workspace name." },
             status: :unprocessable_entity
    end
  end

  def destroy_workspace
    ws = @active_workspace
    return render json: { ok: false, error: "Workspace not found." }, status: :not_found unless ws

    # ✅ Server-side enforcement: must type DELETE
    unless params[:confirm].to_s == "DELETE"
      return render json: { ok: false, error: "Type DELETE to confirm." }, status: :unprocessable_entity
    end

    rid = request.request_id
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Rails.logger.info("[WorkspaceDelete] start rid=#{rid} ws=#{ws.id} user=#{current_user&.id}")

    # Route after delete:
    # - partner + last workspace => back to partner dashboard
    # - non-partner + another workspace => switch to it and stay logged in
    # - non-partner + no workspace left => sign out
    next_ws =
      current_user.workspaces
                  .where(archived_at: nil)
                  .where.not(id: ws.id)
                  .order(:created_at)
                  .first

    should_logout_after_delete = false

    if current_user.respond_to?(:partner?) && current_user.partner? && next_ws.nil?
      session[:partner_mode] = true
      session.delete(:active_workspace_id)
      session.delete(:last_customer_workspace_id)
      redirect_url = partner_dashboard_path
    elsif next_ws.present?
      session[:partner_mode] = false
      session[:active_workspace_id] = next_ws.id
      redirect_url = dashboard_path
    else
      should_logout_after_delete = true
      session[:partner_mode] = false
      session.delete(:active_workspace_id)
      session.delete(:last_customer_workspace_id)
      redirect_url = new_user_session_path
    end

    # 1) Fast path for UX/SOC2 traceability: archive immediately, then purge async.
    tx_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '5s'")

      got_delete_lock = ActiveRecord::Base.connection.select_value(
        "SELECT pg_try_advisory_xact_lock(947221, #{ws.id.to_i})"
      )
      unless got_delete_lock
        raise WorkspaceDeleteBusy, "workspace delete already in progress"
      end

      Rails.logger.info("[WorkspaceDelete][SOC2] archive_begin rid=#{rid} ws=#{ws.id} user=#{current_user&.id}")
      archive_workspace!(ws)
      Rails.logger.info("[WorkspaceDelete][SOC2] archive_ok rid=#{rid} ws=#{ws.id}")
    end
    tx_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - tx_started) * 1000).round

    WorkspacePurgeJob.perform_later(ws.id, request_id: rid, requested_by: current_user&.id)
    Rails.logger.info("[WorkspaceDelete][SOC2] purge_enqueued rid=#{rid} ws=#{ws.id} archive_ms=#{tx_ms}")

    if should_logout_after_delete
      sign_out(current_user)
    end

    total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info("[WorkspaceDelete] done rid=#{rid} ws=#{ws.id} total_ms=#{total_ms} logout=#{should_logout_after_delete} queued=true")

    render json: {
      ok: true,
      message: "Workspace archived. Data purge and billing cleanup were queued.",
      redirect_url: redirect_url,
      logged_out: should_logout_after_delete
    }
  rescue WorkspaceDeleteBusy => e
    Rails.logger.warn("[WorkspaceDelete] busy rid=#{rid} ws=#{ws&.id} #{e.class}: #{e.message}")
    render json: { ok: false, error: "Workspace is busy right now. Please try again in a moment." }, status: :conflict
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
    Rails.logger.warn("[WorkspaceDelete] lock_timeout_or_deadlock rid=#{rid} ws=#{ws&.id} #{e.class}: #{e.message}")
    render json: { ok: false, error: "Workspace is busy right now. Please retry in 10-20 seconds." }, status: :conflict
  rescue ActiveRecord::QueryCanceled => e
    Rails.logger.warn("[WorkspaceDelete] query_canceled rid=#{rid} ws=#{ws&.id} #{e.class}: #{e.message}")
    render json: { ok: false, error: "Workspace deletion timed out while cleaning data. Please retry once; if it repeats, we need to run a deeper cleanup pass." }, status: :unprocessable_entity
  rescue Stripe::StripeError => e
    Rails.logger.warn("[WorkspaceDelete] stripe_failed rid=#{rid} ws=#{ws&.id} #{e.class}: #{e.message}")
    # Workspace is already archived/purged at this point; caller gets actionable follow-up.
    render json: { ok: false, error: "Workspace archived, but Stripe cancellation failed. Please retry billing sync." }, status: :unprocessable_entity
  rescue => e
    Rails.logger.warn("[WorkspaceDelete] failed rid=#{rid} ws=#{ws&.id} #{e.class}: #{e.message}")
    Rails.logger.warn("[WorkspaceDelete] backtrace rid=#{rid} #{Array(e.backtrace).first(8).join(' | ')}")
    render json: { ok: false, error: "Failed to delete workspace." }, status: :unprocessable_entity
  end




  # ============================================================
  # Private helpers
  # ============================================================
  private

  def purge_workspace_dependencies!(ws, rid: nil)
    ws_id = ws.id
    logp = ->(stage) { Rails.logger.info("[WorkspaceDelete] purge rid=#{rid} ws=#{ws_id} stage=#{stage}") }

    # We already hold a per-workspace advisory tx lock in destroy_workspace.
    # Avoid row-locking `workspaces` here: that lock has shown frequent contention
    # from unrelated writes and causes noisy "workspace busy" failures.
    logp.call("lock_workspace_skipped_advisory")
    logp.call("lock_integrations_start")
    Integration.where(workspace_id: ws_id).lock("FOR UPDATE").pluck(:id)
    logp.call("lock_integrations_ok")

    begin
      ws.icon.purge_later if ws.icon.attached?
    rescue => e
      Rails.logger.warn("[WorkspaceDelete] icon purge enqueue failed ws=#{ws_id}: #{e.class}: #{e.message}")
    end

    integration_ids      = Integration.where(workspace_id: ws_id).select(:id)
    group_ids            = Group.where(workspace_id: ws_id).select(:id)
    insight_ids          = Insight.where(workspace_id: ws_id).select(:id)
    conversation_ids     = ::AiChat::Conversation.where(workspace_id: ws_id).select(:id)
    clara_overview_ids   = ClaraOverview.where(workspace_id: ws_id).select(:id)

    insight_pipeline_run_ids = InsightPipelineRun.where(workspace_id: ws_id).select(:id)
    workspace_template_override_ids = WorkspaceInsightTemplateOverride.where(workspace_id: ws_id).select(:id)

    team_ids             = Team.where(integration_id: integration_ids).select(:id)
    channel_ids          = Channel.where(integration_id: integration_ids).select(:id)
    integration_user_ids = IntegrationUser.where(integration_id: integration_ids).select(:id)
    message_ids          = Message.where(integration_id: integration_ids).select(:id)
    model_test_ids       = ModelTest.where(integration_id: integration_ids).select(:id)

    # ---- 1) AI Chat ----
    logp.call("delete_ai_chat_start")
    ::AiChat::Message.where(ai_chat_conversation_id: conversation_ids).delete_all
    ::AiChat::Conversation.where(id: conversation_ids).delete_all
    logp.call("delete_ai_chat_ok")

    # ---- 2) CLARA overviews ----
    ClaraOverview.where(id: clara_overview_ids).delete_all

    # ---- 3) Notifications ----
    NotificationPreference.where(workspace_id: ws_id).delete_all
    WorkspaceNotificationPermission.where(workspace_id: ws_id).delete_all

    # ---- 3b) Insight pipeline / template workspace overrides ----
    InsightPipelineRun.where(id: insight_pipeline_run_ids).delete_all
    WorkspaceInsightTemplateOverride.where(id: workspace_template_override_ids).delete_all

    # ---- 4) Insights ----
    logp.call("delete_insights_start")
    InsightDelivery.where(insight_id: insight_ids).delete_all
    InsightDriverItem.where(insight_id: insight_ids).delete_all
    Insight.where(id: insight_ids).delete_all
    InsightPipelineRun.where(workspace_id: ws_id).delete_all
    logp.call("delete_insights_ok")

    # ---- 5) Workspace invites ----
    WorkspaceInvite.where(workspace_id: ws_id).delete_all

    # ---- 6) Teams/channels memberships (must be gone before channels/integration_users) ----
    logp.call("delete_memberships_start")
    TeamMembership.where(team_id: team_ids).delete_all
    TeamMembership.where(integration_user_id: integration_user_ids).delete_all
    ChannelMembership.where(channel_id: channel_ids).delete_all
    ChannelMembership.where(integration_id: integration_ids).delete_all
    ChannelMembership.where(integration_user_id: integration_user_ids).delete_all
    logp.call("delete_memberships_ok")

    # ---- 7) Groups (FK: group_members -> groups/integration_users) ----
    # ✅ Delete by BOTH predicates to survive any drift/inconsistent rows
    GroupMember.where(group_id: group_ids).delete_all
    GroupMember.where(integration_user_id: integration_user_ids).delete_all
    Group.where(id: group_ids).delete_all

    # ---- 8) Inference/test artifacts ----
    logp.call("delete_inference_artifacts_start")
    Detection.where(message_id: message_ids).delete_all
    Detection.where(model_test_id: model_test_ids).delete_all
    ModelTestDetection.where(message_id: message_ids).delete_all

    AsyncInferenceResult
      .where(model_test_id: model_test_ids)
      .or(AsyncInferenceResult.where(message_id: message_ids))
      .delete_all

    ModelTestDetection.where(model_test_id: model_test_ids).delete_all
    ModelTest.where(id: model_test_ids).delete_all
    logp.call("delete_inference_artifacts_ok")

    # ---- 9) Messages ----
    logp.call("delete_messages_start")
    ReferenceMention.where(message_id: message_ids).delete_all
    Message.where(id: message_ids).delete_all
    logp.call("delete_messages_ok")

    # ---- 10) Channel identities (FK to channels + integration_users) ----
    ChannelIdentity.where(channel_id: channel_ids).delete_all
    ChannelIdentity.where(integration_id: integration_ids).delete_all
    ChannelIdentity.where(integration_user_id: integration_user_ids).delete_all

    # ---- 11) Channels ----
    Channel.where(id: channel_ids).delete_all

    # ---- 12) Teams ----
    Team.where(id: team_ids).delete_all

    # ---- 13) Integration users ----
    logp.call("delete_integration_users_start")
    WorkspaceInvite.where(integration_user_id: integration_user_ids).delete_all
    IntegrationUser.where(id: integration_user_ids).delete_all
    logp.call("delete_integration_users_ok")

    # ---- 14) Workspace users ----
    # Keep owner membership metadata for audit/history; remove everyone else.
    WorkspaceUser
      .where(workspace_id: ws_id)
      .where.not("is_owner = ? OR role = ? OR user_id = ?", true, "owner", ws.owner_id)
      .delete_all

    # ---- 15) Rollups ----
    InsightDetectionRollup.where(workspace_id: ws_id).delete_all
    WorkspaceInsightTemplateOverride.where(workspace_id: ws_id).delete_all

    # ---- 16) Integrations ----
    Integration.where(id: integration_ids).delete_all
    logp.call("delete_integrations_ok")

    # NOTE: Subscriptions and Charges are intentionally PRESERVED.
    # The workspace row is soft-deleted (archived_at set) so we retain
    # stripe_customer_id + full financial history for accounting,
    # refunds, payouts, and audit purposes.

    true
  end

  def with_workspace_delete_retries!(ws:, rid: nil, max_attempts: 3)
    attempts = 0
    begin
      attempts += 1
      yield(attempts)
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
      Rails.logger.warn("[WorkspaceDelete] retry rid=#{rid} ws=#{ws&.id} attempt=#{attempts} #{e.class}: #{e.message}")
      raise if attempts >= max_attempts

      sleep(0.15 * attempts)
      retry
    end
  end

  def archive_workspace!(ws)
    archived_name = "#{ws.name.to_s.strip} (archived #{ws.id})".squish
    archived_name = archived_name[0, 60]

    ws.update_columns(
      archived_at: Time.current,
      name: archived_name,
      updated_at: Time.current
    )
  end



  def require_workspace_owner!
    ws = @active_workspace
    return deny_owner_only! unless ws && current_user

    wu = ws.workspace_users.find_by(user_id: current_user.id)

    is_owner =
      (wu&.is_owner? == true) ||
      (wu&.role.to_s == "owner") ||
      (ws.owner_id.present? && ws.owner_id == current_user.id)

    return if is_owner

    deny_owner_only!
  end

  def deny_owner_only!
    respond_to do |format|
      format.html { redirect_to settings_path, alert: "Only the workspace owner can archive a workspace." }
      format.json { render json: { ok: false, error: "owner_only" }, status: :forbidden }
    end
  end

  def cancel_stripe_for_workspace!(ws)
    ws.subscriptions
      .where.not(stripe_subscription_id: [nil, ""])
      .find_each do |sub|

      next if sub.status.to_s == "canceled"

      sid = sub.stripe_subscription_id.to_s
      next if sid.blank?

      begin
        # Immediate cancellation (works across Stripe gem versions)
        Stripe::Subscription.cancel(sid)
      rescue Stripe::InvalidRequestError => e
        # If Stripe no longer has this sub (already canceled/deleted), don't block workspace deletion.
        Rails.logger.info("[WorkspaceDelete] Stripe subscription #{sid} not cancelable: #{e.message}")
      end

      # Best-effort local mark
      begin
        sub.update!(status: "canceled")
      rescue
        # ignore
      end
    end
  end




  # Single place to enqueue a Stripe qty sync (debounced in job/service).
  # Use this after any seat-affecting operation, especially when using delete_all.
  def queue_stripe_qty_sync!
    return unless @active_workspace
    SyncStripeSubscriptionQtyJob.perform_later(@active_workspace.id)
  rescue => e
    Rails.logger.warn("[Settings] queue_stripe_qty_sync failed: #{e.class}: #{e.message}")
  end

  def notification_preference_for_current_user
    NotificationPreference.find_or_create_by!(workspace: @active_workspace, user: current_user)
  end

  def notification_account_type_for(user)
    wu = user.workspace_users.find_by(workspace: @active_workspace)
    return "owner"  if wu&.owner?
    return "admin"  if wu&.admin?
    return "viewer" if wu&.viewer?
    return "user"   if wu.present?
    "no_account"
  end

  def workspace_owner_or_admin?
    wu = current_user.workspace_users.find_by(workspace: @active_workspace)
    wu&.owner? || wu&.admin?
  end

  def channel_available?(key)
    availability = channel_availability
    return true if key.to_s == "email"
    availability[key.to_sym] == true
  end

  def channel_defaults
    { email: true, slack: true, teams: false }
  end

  def channel_settings_for(preference)
    channel_availability.each_with_object({}) do |(key, available), memo|
      next memo[key] = false unless available
      memo[key] = preference.channel_enabled?(key, default: channel_defaults[key])
    end
  end

  def type_settings_for(preference, allowed_types)
    allowed_types.each_with_object({}) do |key, memo|
      memo[key] = preference.type_enabled?(key, allowed_types: allowed_types, default: false)
    end
  end

  def build_notification_settings_payload
    @channel_availability = channel_availability

    @preference =
      NotificationPreference.find_by(workspace: @active_workspace, user: current_user) ||
      NotificationPreference.new(workspace: @active_workspace, user: current_user)

    @notification_account_type = notification_account_type_for(current_user)
    @workspace_permissions     = workspace_permissions_by_type

    user_permission = @workspace_permissions[@notification_account_type]
    allowed_types   = user_permission.enabled? ? user_permission.allowed_types : []

    @type_settings    = type_settings_for(@preference, allowed_types)
    @channel_settings = channel_settings_for(@preference)
    @allowed_types    = allowed_types
    @show_admin_panel = workspace_owner_or_admin?
  end

  def notification_payload_json
    {
      channels: @channel_settings,
      types: @type_settings,
      allowed_types: @allowed_types,
      account_type: @notification_account_type,
      permissions: workspace_owner_or_admin? ? serialize_permissions(@workspace_permissions) : {}
    }
  end

  def channel_availability
    return @channel_availability if defined?(@channel_availability)

    @channel_availability = {
      email: true,
      slack: Integration.joins(:integration_users)
                        .where(workspace_id: @active_workspace.id,
                               kind: "slack",
                               integration_users: { user_id: current_user.id })
                        .exists?,
      teams: Integration.joins(:integration_users)
                        .where(workspace_id: @active_workspace.id,
                               kind: "microsoft_teams",
                               integration_users: { user_id: current_user.id })
                        .exists?
    }
  end

  def workspace_permissions_by_type
    WorkspaceNotificationPermission::ACCOUNT_TYPES.index_with do |account_type|
      WorkspaceNotificationPermission.for(@active_workspace, account_type)
    end
  end

  def workspace_permission_for(account_type)
    WorkspaceNotificationPermission.for(@active_workspace, account_type)
  end

  def serialize_permissions(map)
    map.transform_values do |permission|
      { enabled: permission.enabled?, allowed_types: permission.allowed_types }
    end
  end

  def build_integration_state(kind)
    payload = {
      workspace_id: @active_workspace.id,
      user_id:      current_user.id,
      kind:         kind,
      ts:           Time.current.to_i
    }

    verifier = Rails.application.message_verifier("integration_install_state")
    verifier.generate(payload)
  end
end
