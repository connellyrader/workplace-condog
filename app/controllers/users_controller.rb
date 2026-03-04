class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_workspace, only: [:index, :new, :create, :invite]

  def index
    # Show all users for a given workspace
    @users = @workspace.users
  end

  def new
    # Form to invite a new user by email, for example
    # This is optional—some flows might skip direct sign-up and rely on Slack SSO links
    @user = User.new
  end

  def create
    # Create user in the DB, then link them to the workspace
    # In reality, you might send an invite email or Slack DM
    @user = User.new(user_params)
    if @user.save
      # Link to workspace
      UserWorkspace.create!(user: @user, workspace: @workspace)
      redirect_to workspace_users_path(@workspace), notice: "User invited."
    else
      render :new
    end
  end

  # Another approach: "invite" action that sends a Slack DM or email link
  def invite
    # Suppose you pass email in params[:email]
    email = params[:email]
    user = User.find_or_initialize_by(email: email)
    if user.new_record?
      user.password = Devise.friendly_token[0,20]  # if using normal sign-up
      user.save!
    end
    # Link to workspace
    UserWorkspace.find_or_create_by!(user: user, workspace: @workspace)

    # Optionally send Slack DM using current_user's slack_history_token
    # ...
    redirect_to workspace_users_path(@workspace), notice: "Invite sent to #{email}"
  end

  def user_integrate
    @onboarding = true

    # Defaults
    @connect_integration_path  = integrations_path
    @connect_integration_label = "View Integrations"

    ws = @active_workspace
    return unless ws && current_user

    integrations =
      ws.integrations
        .where(kind: %w[slack microsoft_teams])
        .order(:created_at)

    user_ius =
      current_user.integration_users
                  .where(integration_id: integrations.select(:id))
                  .index_by(&:integration_id)

    target =
      integrations.detect do |integration|
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

        !connected_for_user
      end

    return unless target

    state = build_integration_state(target.kind.to_s)

    case target.kind.to_s
    when "slack"
      @connect_integration_label = "Connect Slack"
      @connect_integration_path  = slack_history_start_path(state: state)
    when "microsoft_teams"
      @connect_integration_label = "Connect Microsoft Teams"
      @connect_integration_path  = teams_connect_path(state: state)
    end
  end

  def user_done
    @onboarding = true
  end

  private

  def set_workspace
    @workspace = current_user.workspaces.where(archived_at: nil).find(params[:workspace_id])

    # Check that current_user is owner or can manage sub-users
    unless current_user.workspace_users.find_by(workspace: @workspace)&.is_owner?
      redirect_to workspaces_path, alert: "Not authorized to manage users."
    end
  end

  # Same signing logic as SettingsController#build_integration_state
  def build_integration_state(kind)
    payload = {
      workspace_id: @active_workspace.id,
      user_id:      current_user.id,
      kind:         kind, # "slack" or "microsoft_teams"
      ts:           Time.current.to_i
    }

    verifier = Rails.application.message_verifier("integration_install_state")
    verifier.generate(payload)
  end

  def user_params
    params.require(:user).permit(:email, :first_name, :last_name)
  end
end
