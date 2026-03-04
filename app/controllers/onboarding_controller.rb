class OnboardingController < ApplicationController
  # Ensure a Stripe customer exists for workspace-level billing actions.
  before_action :ensure_workspace_has_integration!, only: [
    :start, :members, :channels, :setup_status,
    :create_group, :update_group, :destroy_group,
    :plan, :start_trial
  ]

  before_action :redirect_if_subscribed!, only: [:start, :plan, :start_trial]

  before_action :ensure_stripe_customer!, only: [:plan, :start_trial]
  skip_before_action :ensure_workspace_ready!

  # Manual invoicing eligibility threshold
  MANUAL_INVOICE_MIN_SEATS = 100
  MANUAL_INVOICE_DAYS_UNTIL_DUE = 30

  def start
    @onboarding = true

    @total_members =
      IntegrationUser
        .joins(:integration)
        .where(
          integrations: { workspace_id: @active_workspace.id },
          active: true,
          is_bot: false
        ).count

    base_channel_scope =
      Channel
        .joins(:integration)
        .where(
          integrations: { workspace_id: @active_workspace.id },
          is_archived: false,
          kind: "public_channel"
        )
        .left_joins(channel_memberships: :integration_user)
        .select(<<~SQL.squish)
          channels.*,
          COUNT(
            DISTINCT CASE
              WHEN channel_memberships.left_at IS NULL
               AND integration_users.is_bot = FALSE
               AND integration_users.active = TRUE
              THEN channel_memberships.integration_user_id
            END
          ) AS member_count
        SQL
        .group("channels.id")
        .having(<<~SQL.squish)
          COUNT(
            DISTINCT CASE
              WHEN channel_memberships.left_at IS NULL
               AND integration_users.is_bot = FALSE
               AND integration_users.active = TRUE
              THEN channel_memberships.integration_user_id
            END
          ) > 0
        SQL
        .order("member_count DESC")

    @slack_channels = base_channel_scope.where(integrations: { kind: "slack" })
    @teams_channels = base_channel_scope.where(integrations: { kind: "microsoft_teams" }).includes(:team)

    @teams =
      Team
        .joins(:integration)
        .where(integrations: { workspace_id: @active_workspace.id, kind: "microsoft_teams" })
        .left_joins(team_memberships: :integration_user)
        .select(<<~SQL.squish)
          teams.*,
          COUNT(
            DISTINCT CASE
              WHEN integration_users.is_bot = FALSE
               AND integration_users.active = TRUE
              THEN team_memberships.integration_user_id
            END
          ) AS member_count
        SQL
        .group("teams.id")
        .having(<<~SQL.squish)
          COUNT(
            DISTINCT CASE
              WHEN integration_users.is_bot = FALSE
               AND integration_users.active = TRUE
              THEN team_memberships.integration_user_id
            END
          ) > 0
        SQL
        .order("member_count DESC")

    if params[:group_id].present?
      @group = @active_workspace.groups
                                .includes(group_members: :integration_user)
                                .find(params[:group_id])

      @selected_ids = @group.group_members.pluck(:integration_user_id).map!(&:to_s)
      @group_name   = @group.name

      session[:selected_user_ids] = @selected_ids
    else
      @group        = nil
      @selected_ids = Array(session[:selected_user_ids]).map!(&:to_s)
      @group_name   = ""
    end

    @can_delete_group =
      @group.present? &&
      Group.where(workspace_id: @active_workspace.id)
           .where.not(id: @group.id)
           .exists?

    @has_any_groups = Group.where(workspace_id: @active_workspace.id).exists?
  end

  def plan
    @onboarding = true

    # ---- Seats for pricing ----
    @groups = Group.where(workspace_id: @active_workspace.id)
                   .includes(group_members: :integration_user)

    selected_ids =
      GroupMember.joins(:group)
                 .where(groups: { workspace_id: @active_workspace.id })
                 .distinct
                 .pluck(:integration_user_id)

    @selected_member_count = selected_ids.size

    @selected_preview_users =
      if selected_ids.any?
        IntegrationUser
          .joins(:integration)
          .where(
            id: selected_ids,
            integrations: { workspace_id: @active_workspace.id }
          )
          .order(Arel.sql("COALESCE(integration_users.display_name, integration_users.real_name) ASC"))
          .limit(3)
      else
        []
      end

    workspace_user = @active_workspace.workspace_users.find_by(user_id: current_user.id)
    owner_iu       = workspace_user&.integration_user_for_workspace

    @owner_selected = owner_iu && selected_ids.include?(owner_iu.id)

    @seat_count =
      if @owner_selected
        @selected_member_count
      else
        @selected_member_count + 1
      end

    price, amount_cents   = stripe_amount_for_count(@seat_count)
    @stripe_price         = price
    @billing_amount_cents = amount_cents || 0
    @avg_ppu_cents        = @seat_count.positive? ? (@billing_amount_cents.to_f / @seat_count).round : 0

    tz = current_user.try(:timezone) || "America/New_York"
    @trial_ends_on = 14.days.from_now.in_time_zone(tz).to_date

    # ---- Manual invoicing eligibility (UI toggle) ----
    @manual_invoice_min_seats = MANUAL_INVOICE_MIN_SEATS
    @manual_invoice_eligible  = @seat_count >= MANUAL_INVOICE_MIN_SEATS

    # Always create SetupIntent so default mode (auto) works.
    # If user toggles manual, we simply bypass confirmSetup + bypass requiring a PM.
    setup_intent = Stripe::SetupIntent.create(
      customer: @active_workspace.stripe_customer_id,
      payment_method_types: ["card", "us_bank_account"],
      payment_method_options: {
        us_bank_account: {
          verification_method: "instant"
        }
      }
    )
    @setup_intent_client_secret = setup_intent.client_secret
    @setup_intent_id            = setup_intent.id

    session[:selected_user_ids] = nil
  end

  def start_trial
    ws = @active_workspace or return head :unauthorized

    selected_count =
      GroupMember.joins(:group)
                 .where(groups: { workspace_id: ws.id })
                 .distinct
                 .count(:integration_user_id)

    if selected_count < 2
      flash[:alert] = "Please select at least 2 members."
      return redirect_to plan_path
    end

    seat_count = selected_count + 1

    manual_requested = params[:billing_mode].to_s == "manual"
    manual_eligible  = seat_count >= MANUAL_INVOICE_MIN_SEATS

    customer_id = ws.stripe_customer_id
    price_id    = "price_1RQWKcGfpLtyy7R52c0tJ2dv"
    trial_end_ts = 14.days.from_now.end_of_day.to_i

    if manual_requested && manual_eligible
      # Manual invoicing path: no payment method required
      subscription = Stripe::Subscription.create(
        customer: customer_id,
        items: [{ price: price_id, quantity: seat_count }],
        trial_end: trial_end_ts,
        proration_behavior: "none",
        collection_method: "send_invoice",
        days_until_due: MANUAL_INVOICE_DAYS_UNTIL_DUE
      )

      price, amount_cents = stripe_amount_for_count(seat_count)

      Subscription.create!(
        user: current_user,
        workspace: ws,
        stripe_subscription_id: subscription.id,
        status: subscription.status,
        started_on: Date.today,
        expires_on: Time.at(subscription.trial_end || trial_end_ts).to_date,
        amount: amount_cents,
        interval: (price.recurring&.interval || "month")
      )

      Notifiers::PartnerNotifier.new_customer(
        subscription: subscription,
        customer: current_user,
        amount_cents: amount_cents,
        currency: price&.currency
      )

      session[:selected_user_ids] = nil
      Notifiers::UpcomingChargeNotifier.call(
        workspace: ws,
        amount_cents: amount_cents,
        currency: price&.currency,
        billing_date: subscription.trial_end || trial_end_ts,
        seats: seat_count
      )
      redirect_to root_path, notice: "Your free trial has started (manual invoicing enabled)."
      return
    end

    # Default: autopay required
    pm_id = params[:payment_method].to_s
    if pm_id.blank?
      flash[:alert] = "Please enter a payment method."
      return redirect_to plan_path
    end

    Stripe::PaymentMethod.attach(pm_id, { customer: customer_id })
    Stripe::Customer.update(customer_id, {
      invoice_settings: { default_payment_method: pm_id }
    })

    subscription = Stripe::Subscription.create(
      customer: customer_id,
      items: [{ price: price_id, quantity: seat_count }],
      trial_end: trial_end_ts,
      proration_behavior: "none",
      payment_behavior: "default_incomplete",
      expand: ["latest_invoice.payment_intent"]
    )

    price, amount_cents = stripe_amount_for_count(seat_count)

    Subscription.create!(
      user: current_user,
      workspace: ws,
      stripe_subscription_id: subscription.id,
      status: subscription.status,
      started_on: Date.today,
      expires_on: Time.at(subscription.trial_end || trial_end_ts).to_date,
      amount: amount_cents,
      interval: (price.recurring&.interval || "month")
    )

    Notifiers::PartnerNotifier.new_customer(
      subscription: subscription,
      customer: current_user,
      amount_cents: amount_cents,
      currency: price&.currency
    )

    session[:selected_user_ids] = nil
    Notifiers::UpcomingChargeNotifier.call(
      workspace: ws,
      amount_cents: amount_cents,
      currency: price&.currency,
      billing_date: subscription.trial_end || trial_end_ts,
      seats: seat_count
    )
    redirect_to root_path, notice: "Your free trial has started."
  rescue Stripe::StripeError => e
    Rails.logger.error("[Stripe Start Trial] #{e.class}: #{e.message}")
    flash[:alert] = e.message || "There was a problem starting your trial. Please try again."
    redirect_to plan_path
  end

  def members
    users =
      IntegrationUser
        .joins(:integration)
        .where(
          integrations: { workspace_id: @active_workspace.id },
          is_bot: false,
          active: true
        )

    if params[:channel_id].present? && params[:channel_id] != 'pseudo_everyone'
      users = users.joins("INNER JOIN channel_memberships cm ON cm.integration_user_id = integration_users.id")
                   .where("cm.channel_id = ? AND cm.left_at IS NULL", params[:channel_id])
    end

    if params[:team_id].present?
      users = users.joins("INNER JOIN team_memberships tm ON tm.integration_user_id = integration_users.id")
                   .where("tm.team_id = ?", params[:team_id])
    end

    if params[:q].present?
      q = "%#{params[:q].strip}%"
      users = users.where(
        "integration_users.display_name ILIKE ? OR integration_users.real_name ILIKE ?",
        q, q
      )
    end

    @users =
      users
        .order(Arel.sql("COALESCE(integration_users.display_name, integration_users.real_name) ASC"))
        .limit(200)

    @selected_ids =
      Array(params[:selected_ids].presence || session[:selected_user_ids]).map!(&:to_s)

    render partial: "onboarding/members",
           locals: { users: @users, selected_ids: @selected_ids }
  end

  def save_selection
    session[:selected_user_ids] = Array(params[:user_ids]).map!(&:to_s)
    head :ok
  end

  def create_group
    ws = @active_workspace or return head :unauthorized
    group = ws.groups.find_or_create_by!(name: "Everyone")
    submitted_ids = Array(params[:user_ids]).map!(&:to_i).uniq

    GroupMember.transaction do
      GroupMember.where(group_id: group.id)
                 .where.not(integration_user_id: submitted_ids)
                 .delete_all

      existing_ids = GroupMember.where(group_id: group.id).pluck(:integration_user_id)
      (submitted_ids - existing_ids).each do |iu_id|
        GroupMember.create!(group_id: group.id, integration_user_id: iu_id)
      end
    end

    session[:selected_user_ids] = nil
    redirect_to plan_path, notice: "Selection saved."
  end

  def update_group
    ws    = @active_workspace or return head :unauthorized
    group = ws.groups.find(params[:id])

    group.update!(name: params[:group_name]) if params[:group_name].present?
    submitted_ids = Array(params[:user_ids]).map!(&:to_i).uniq

    GroupMember.transaction do
      GroupMember.where(group_id: group.id)
                 .where.not(integration_user_id: submitted_ids)
                 .delete_all

      existing_ids = GroupMember.where(group_id: group.id).pluck(:integration_user_id)
      (submitted_ids - existing_ids).each do |iu_id|
        GroupMember.create!(group_id: group.id, integration_user_id: iu_id)
      end
    end

    session[:selected_user_ids] = nil
    redirect_to plan_path, notice: "Selection saved."
  end

  def destroy_group
    ws = @active_workspace or return head :unauthorized
    group = Group.where(workspace_id: ws.id).find(params[:id])

    total = Group.where(workspace_id: ws.id).count
    if total <= 1
      redirect_to start_path(group_id: group.id), alert: "You must keep at least one group."
      return
    end

    group.destroy!
    redirect_to plan_path, notice: "Group deleted."
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def setup_status
    wid = @active_workspace.id
    integration = Integration.where(workspace_id: wid).order(created_at: :desc).first

    unless integration
      render json: {
        ready: false,
        counts: { "channels" => 0, "users" => 0, "memberships" => 0 },
        stable_runs: 0,
        integration_id: nil,
        integration_kind: nil,
        setup_status: nil,
        setup_step: nil,
        setup_progress: nil
      }
      return
    end

    cached_channels     = integration.setup_channels_count.to_i
    cached_users        = integration.setup_users_count.to_i
    cached_memberships  = integration.setup_memberships_count.to_i

    use_cached =
      integration.setup_status.to_s == "complete" ||
      (cached_channels > 0 || cached_users > 0 || cached_memberships > 0)

    channels_count =
      if use_cached && cached_channels > 0
        cached_channels
      else
        Channel.where(integration_id: integration.id, kind: "public_channel", is_archived: false).count
      end

    users_count =
      if use_cached && cached_users > 0
        cached_users
      else
        IntegrationUser.where(integration_id: integration.id, active: true, is_bot: false).count
      end

    memberships_count =
      if use_cached && cached_memberships > 0
        cached_memberships
      else
        ChannelMembership.where(integration_id: integration.id, left_at: nil).count
      end

    current = {
      "channels" => channels_count.to_i,
      "users" => users_count.to_i,
      "memberships" => memberships_count.to_i
    }

    last = session[:setup_last_counts] || {}
    stable_runs = (session[:setup_stable_runs] || 0).to_i
    last_integration_id = session[:setup_last_integration_id].to_i

    if last_integration_id != integration.id
      stable_runs = 0
    elsif last == current
      stable_runs += 1
    else
      stable_runs = 0
    end

    session[:setup_last_counts] = current
    session[:setup_stable_runs] = stable_runs
    session[:setup_last_integration_id] = integration.id

    setup_status = integration.setup_status.to_s

    if setup_status == "failed"
      render json: {
        ready: false,
        failed: true,
        error: integration.setup_error,
        counts: current,
        stable_runs: stable_runs,
        integration_id: integration.id,
        integration_kind: integration.kind,
        setup_status: setup_status,
        setup_step: integration.setup_step,
        setup_progress: integration.setup_progress
      }
      return
    end

    if setup_status == "complete"
      render json: {
        ready: true,
        counts: current,
        stable_runs: stable_runs,
        integration_id: integration.id,
        integration_kind: integration.kind,
        setup_status: setup_status,
        setup_step: integration.setup_step,
        setup_progress: integration.setup_progress
      }
      return
    end

    has_minimum = current["channels"].positive? && current["memberships"].positive?
    ready = has_minimum && stable_runs >= 5

    render json: {
      ready: ready,
      counts: current,
      stable_runs: stable_runs,
      integration_id: integration.id,
      integration_kind: integration.kind,
      setup_status: setup_status.presence || "unknown",
      setup_step: integration.setup_step,
      setup_progress: integration.setup_progress
    }
  end

  def channels
    wid = @active_workspace.id

    base_channel_scope =
      Channel
        .joins(:integration)
        .where(integrations: { workspace_id: wid }, kind: "public_channel", is_archived: false)
        .left_joins(channel_memberships: :integration_user)
        .select(<<~SQL.squish)
          channels.*,
          COUNT(
            DISTINCT CASE
              WHEN channel_memberships.left_at IS NULL
               AND integration_users.is_bot = FALSE
               AND integration_users.active = TRUE
              THEN channel_memberships.integration_user_id
            END
          ) AS member_count
        SQL
        .group("channels.id")
        .having(<<~SQL.squish)
          COUNT(
            DISTINCT CASE
              WHEN channel_memberships.left_at IS NULL
               AND integration_users.is_bot = FALSE
               AND integration_users.active = TRUE
              THEN channel_memberships.integration_user_id
            END
          ) > 0
        SQL
        .order("member_count DESC")

    @slack_channels = base_channel_scope.where(integrations: { kind: "slack" })
    @teams_channels = base_channel_scope.where(integrations: { kind: "microsoft_teams" }).includes(:team)

    @teams =
      Team
        .joins(:integration)
        .where(integrations: { workspace_id: wid, kind: "microsoft_teams" })
        .left_joins(team_memberships: :integration_user)
        .select(<<~SQL.squish)
          teams.*,
          COUNT(
            DISTINCT CASE
              WHEN integration_users.is_bot = FALSE
               AND integration_users.active = TRUE
              THEN team_memberships.integration_user_id
            END
          ) AS member_count
        SQL
        .group("teams.id")
        .having(<<~SQL.squish)
          COUNT(
            DISTINCT CASE
              WHEN integration_users.is_bot = FALSE
               AND integration_users.active = TRUE
              THEN team_memberships.integration_user_id
            END
          ) > 0
        SQL
        .order("member_count DESC")

    render partial: "onboarding/channels",
           locals: { slack_channels: @slack_channels, teams_channels: @teams_channels, teams: @teams }
  end

  private

  def ensure_workspace_has_integration!
    return unless @active_workspace

    has_integration = Integration.where(workspace_id: @active_workspace.id).exists?
    return if has_integration

    respond_to do |format|
      format.html do
        redirect_to integrations_path, alert: "Connect Slack or Microsoft Teams to continue setup."
      end
      format.json do
        render json: { ok: false, error: "missing_integration", redirect_url: integrations_path }, status: :unprocessable_entity
      end
    end
  end

  # Returns [Stripe::Price, amount_cents]
  def stripe_amount_for_count(count)
    price = Stripe::Price.retrieve(
      { id: 'price_1RQWKcGfpLtyy7R52c0tJ2dv', expand: ['product', 'tiers'] }
    )

    tiers = Array(price.tiers)
    mode  = price.tiers_mode

    amount_cents =
      if tiers.any?
        if mode == 'volume'
          tier = tiers.find { |t|
            up_to = (t.up_to == 'inf') ? Float::INFINITY : t.up_to.to_i
            count <= up_to
          } || tiers.last

          if tier.respond_to?(:flat_amount) && tier.flat_amount
            tier.flat_amount
          elsif tier.respond_to?(:unit_amount) && tier.unit_amount
            tier.unit_amount * count
          else
            0
          end
        else
          remaining  = count
          amount     = 0
          prev_up_to = 0

          tiers.each do |t|
            up_to        = (t.up_to == 'inf') ? Float::INFINITY : t.up_to.to_i
            qty_in_tier  = [remaining, up_to - prev_up_to].min
            break if qty_in_tier <= 0

            if t.respond_to?(:flat_amount) && t.flat_amount
              amount = t.flat_amount
            else
              unit = t.respond_to?(:unit_amount) ? t.unit_amount.to_i : 0
              amount += unit * qty_in_tier
            end

            remaining  -= qty_in_tier
            prev_up_to  = up_to
          end
          amount
        end
      else
        (price.unit_amount || 0) * count
      end

    [price, amount_cents.to_i]
  end

  def ensure_stripe_customer!
    ws = @active_workspace or return
    return if ws.stripe_customer_id.present?

    customer = Stripe::Customer.create(
      email: current_user.email,
      name: current_user.respond_to?(:name) ? current_user.name : nil,
      metadata: { app_user_id: current_user.id, workspace_id: ws.id }
    )

    ws.update!(stripe_customer_id: customer.id)
  end


  def redirect_if_subscribed!
    ws = @active_workspace
    return unless ws

    already_subscribed =
      ws.subscriptions.where(status: %w[active trialing]).exists?

    return unless already_subscribed

    respond_to do |format|
      format.html do
        redirect_to dashboard_path, notice: "Your workspace already has an active subscription."
      end
      format.json do
        render json: { ok: false, error: "already_subscribed", redirect_url: dashboard_path },
               status: :unprocessable_entity
      end
    end
  end
end
