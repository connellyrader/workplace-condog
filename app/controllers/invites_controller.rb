# app/controllers/invites_controller.rb
class InvitesController < ApplicationController
  skip_before_action :authenticate_user!, only: [:show]

  # Pending-invite flow must not assume an active workspace exists.
  skip_before_action :set_active_workspace,   raise: false
  skip_before_action :ensure_workspace_ready!, raise: false
  skip_before_action :set_right_panel_flags,  raise: false

  before_action :load_invite_by_token!, only: [:show, :accept, :decline]
  before_action :load_pending_invite_by_id!, only: [:accept_pending, :decline_pending]

  # GET /invites/pending
  def pending
    authenticate_user!
    @onboarding = true

    email = current_user.email.to_s.strip.downcase

    @pending_invites =
      WorkspaceInvite
        .where(email: email)
        .pending_status
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
        .includes(:workspace, :invited_by, :integration_user)
        .order(created_at: :desc)

    # If there are none, just go home.
    if @pending_invites.blank?
      redirect_to dashboard_path
      return
    end

    render :pending
  end

  # GET /invites/:token
  def show
    @onboarding = true
    @invite_token = params[:token].to_s

    unless user_signed_in?
      store_pending_invite_token!
      redirect_to new_user_session_path
      return
    end

    if invite_expired?
      expire_invite_if_pending!
      render :show
      return
    end

    if @invite.accepted_status?
      finalize_workspace_context!(@invite.workspace_id)
      redirect_to dashboard_path, notice: "You’re already a member of #{@invite.workspace.name}."
      return
    end

    render :show
  end

  # POST /invites/pending/:id/accept
  def accept_pending
    authenticate_user!
    ensure_pending_invite_is_actionable!

    WorkspaceInvite.transaction do
      # Never allow an invite to grant owner privileges
      requested_role = @invite.role.to_s.presence || "user"
      safe_role      = (requested_role == "owner") ? "admin" : requested_role

      wu = WorkspaceUser.find_or_initialize_by(
        workspace_id: @invite.workspace_id,
        user_id: current_user.id
      )

      wu.role     = safe_role
      wu.is_owner = false
      wu.save!

      attrs = { status: "accepted" }
      attrs[:accepted_at] = Time.current if @invite.respond_to?(:accepted_at=)
      @invite.update!(attrs)

      finalize_workspace_context!(@invite.workspace_id)
    end

    Notifiers::InviteOutcomeNotifier.accepted(invite: @invite)

    clear_pending_invite_token!
    redirect_to dashboard_path, notice: "You’ve joined #{@invite.workspace.name}."
  end

  # POST /invites/pending/:id/decline
  def decline_pending
    authenticate_user!
    ensure_pending_invite_is_actionable!

    WorkspaceInvite.transaction do
      attrs = { status: "canceled" }
      attrs[:canceled_at] = Time.current if @invite.respond_to?(:canceled_at=)
      @invite.update!(attrs)
    end

    Notifiers::InviteOutcomeNotifier.declined(invite: @invite)

    clear_pending_invite_token!
    redirect_to dashboard_path, notice: "Invite declined."
  end

  # POST /invites/:token/accept
  def accept
    authenticate_user!
    ensure_invite_is_actionable!

    if @invite.email.present? && current_user.email.to_s.downcase != @invite.email.to_s.downcase
      redirect_to invite_path(params[:token]), alert: "This invite was sent to a different email address."
      return
    end

    WorkspaceInvite.transaction do
      # Never allow an invite to grant owner privileges
      requested_role = @invite.role.to_s.presence || "user"
      safe_role      = (requested_role == "owner") ? "admin" : requested_role

      wu = WorkspaceUser.find_or_initialize_by(
        workspace_id: @invite.workspace_id,
        user_id: current_user.id
      )

      # Force-correct any existing bad state
      wu.role     = safe_role
      wu.is_owner = false
      wu.save!

      attrs = { status: "accepted" }
      attrs[:accepted_at] = Time.current if @invite.respond_to?(:accepted_at=)
      @invite.update!(attrs)

      finalize_workspace_context!(@invite.workspace_id)
    end

    Notifiers::InviteOutcomeNotifier.accepted(invite: @invite)

    clear_pending_invite_token!
    redirect_to dashboard_path, notice: "You’ve joined #{@invite.workspace.name}."
  end

  # POST /invites/:token/decline
  def decline
    authenticate_user!
    ensure_invite_is_actionable!

    WorkspaceInvite.transaction do
      attrs = { status: "canceled" }
      attrs[:canceled_at] = Time.current if @invite.respond_to?(:canceled_at=)
      @invite.update!(attrs)
    end

    Notifiers::InviteOutcomeNotifier.declined(invite: @invite)

    clear_pending_invite_token!

    if current_user.workspaces.where(archived_at: nil).exists?
      redirect_to dashboard_path, notice: "Invite declined."
      return
    end

    ws_name = current_user.full_name.presence || "#{current_user.email}'s Workspace"
    ws = Workspace.create!(name: ws_name, owner: current_user)
    WorkspaceUser.create!(workspace: ws, user: current_user, is_owner: true, role: "owner")
    finalize_workspace_context!(ws.id)

    redirect_to dashboard_path, notice: "Invite declined. Let’s get your workspace set up."
  end

  private

  def load_invite_by_token!
    token = params[:token].to_s
    @invite = WorkspaceInvite.find_by_token(token)

    if @invite.nil?
      render status: :not_found, plain: "This invite link is invalid."
    end
  end

  def load_pending_invite_by_id!
    return if performed?

    email = current_user&.email.to_s.strip.downcase
    @invite =
      WorkspaceInvite
        .where(email: email)
        .pending_status
        .where(id: params[:id])
        .includes(:workspace, :invited_by, :integration_user)
        .first

    if @invite.nil?
      redirect_to pending_invites_path, alert: "Invite not found or no longer pending."
    end
  end

  def ensure_pending_invite_is_actionable!
    return if performed?

    if invite_expired?
      expire_invite_if_pending!
      redirect_to pending_invites_path, alert: "That invite has expired."
      return
    end

    unless @invite.pending_status?
      redirect_to pending_invites_path, alert: "That invite is no longer pending."
    end
  end

  def invite_expired?
    @invite.expires_at.present? && @invite.expires_at < Time.current
  end

  def expire_invite_if_pending!
    return unless @invite.pending_status?
    return unless invite_expired?

    @invite.update!(status: "expired")
  end

  def ensure_invite_is_actionable!
    return if performed?

    if invite_expired?
      expire_invite_if_pending!
      redirect_to invite_path(params[:token]), alert: "That invite has expired."
      return
    end

    unless @invite.pending_status?
      redirect_to invite_path(params[:token]), alert: "That invite is no longer pending."
    end
  end

  def store_pending_invite_token!
    cookies.signed[:pending_invite_token] = {
      value: params[:token].to_s,
      expires: 30.minutes.from_now,
      httponly: true
    }
  end

  def clear_pending_invite_token!
    cookies.delete(:pending_invite_token)
  end

  def finalize_workspace_context!(workspace_id)
    session[:active_workspace_id] = workspace_id
  end
end
