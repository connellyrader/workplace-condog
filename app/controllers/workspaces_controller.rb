class WorkspacesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_workspace, only: [:show, :edit, :update, :manage_billing]

  def index
    # Show all workspaces the current_user is part of
    @workspaces = current_user.workspaces.where(archived_at: nil)
  end

  def show
    # Basic show page
  end

  def new
    @workspace = Workspace.new
  end

  def create
    @workspace = Workspace.new(workspace_params)
    @workspace.owner = current_user

    if @workspace.save
      WorkspaceUser.create!(
        user:      current_user,
        workspace: @workspace,
        is_owner:  true,
        role:      "owner"
      )

      # Mirror switch behavior so partners don't stay stuck in partner-mode
      # after creating a new customer workspace.
      session[:active_workspace_id] = @workspace.id
      session[:partner_mode] = false
      session.delete(:last_customer_workspace_id)

      Rails.logger.info(
        "[WorkspaceCreate] user_id=#{current_user.id} created_workspace_id=#{@workspace.id} session_active_workspace_id=#{session[:active_workspace_id].inspect} partner_mode=#{session[:partner_mode].inspect}"
      )

      # Keep dashboard filters consistent with workspace switches.
      session.delete(:dash_range_start)
      session.delete(:dash_range_end)
      session.delete(:dash_is_all_time)

      # Go straight to dashboard after create for snappier UX.
      # Session workspace context is already set above.
      redirect_to dashboard_path, notice: "Workspace created!"
    else
      # Keep UX consistent when the form is submitted from a global modal.
      flash[:alert] = @workspace.errors.full_messages.first.presence || "Workspace name cannot be blank."
      flash[:open_new_workspace_modal] = true
      flash[:new_workspace_name] = params.dig(:workspace, :name).to_s

      redirect_back fallback_location: dashboard_path, status: :see_other
    end
  end




  def edit
    # only allow if current_user is owner
    unless current_user.workspace_users.find_by(workspace: @workspace)&.is_owner?
      redirect_to @workspace, alert: "You are not authorized."
    end
  end

  def update
    unless current_user.workspace_users.find_by(workspace: @workspace)&.is_owner?
      redirect_to @workspace, alert: "You are not authorized." and return
    end

    if @workspace.update(workspace_params)
      redirect_to @workspace, notice: "Workspace updated!"
    else
      render :edit
    end
  end

  def manage_billing
    # Show a page to update billing info if is_owner
    unless current_user.workspace_users.find_by(workspace: @workspace)&.is_owner?
      redirect_to @workspace, alert: "Not authorized."
    end
    # For example, you might show a Stripe form or link here
  end

  def switch
    @workspace = workspace_from_switch_params

    # Must belong to the user
    unless current_user.workspaces.exists?(id: @workspace.id)
      demo_allowed = user_can_access_demo_workspace? && demo_workspace && demo_workspace.id == @workspace.id
      unless demo_allowed
        redirect_to dashboard_path, alert: "You are not authorized for that workspace." and return
      end
    end

    # Must not be archived
    if @workspace.archived_at.present?
      redirect_to dashboard_path, alert: "That workspace is archived and cannot be used." and return
    end

    session[:active_workspace_id] = @workspace.id
    session[:partner_mode] = false
    session.delete(:last_customer_workspace_id)

    # Reset date range to default 30 days when switching workspaces
    session.delete(:dash_range_start)
    session.delete(:dash_range_end)
    session.delete(:dash_is_all_time)

    redirect_to dashboard_path
  end


  private

  def set_workspace
    # Never allow raw workspace id enumeration.
    @workspace = current_user.workspaces.where(archived_at: nil).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    # Demo workspace is special-cased.
    if user_can_access_demo_workspace? && demo_workspace && demo_workspace.id.to_s == params[:id].to_s
      @workspace = demo_workspace
    else
      raise
    end
  end

  def workspace_from_switch_params
    # Prefer signed token route
    if params[:token].present?
      return Workspace.find_signed!(params[:token], purpose: "workspace_switch")
    end

    # Legacy numeric id route
    Workspace.find(params[:id])
  end

  def workspace_params
    params.require(:workspace).permit(:name, :slack_team_id, :stripe_customer_id, :subscription_status)
  end
end
