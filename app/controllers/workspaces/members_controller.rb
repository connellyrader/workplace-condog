# app/controllers/workspaces/members_controller.rb
module Workspaces
  class MembersController < ApplicationController
    before_action :authenticate_user!
    before_action :set_workspace
    before_action :ensure_owner!

    # GET /workspaces/:workspace_id/members
    def index
      # load the join-rows, eager-load the actual User if they’re connected
      @members         = @workspace
                           .workspace_users
                           .includes(:user)
                           .order("role DESC, slack_user_id ASC")
      # the ones who haven’t actually connected yet
      @missing_members = @members.reject(&:connected?)
    end

    def invite
      uw = @workspace.workspace_users.find(params[:id])
      send_invite_dm(uw.slack_user_id)
      uw.update!(invited_at: Time.current)    # ← mark timestamp here
      redirect_to workspace_members_path(@workspace),
                  notice: "Invite sent to #{uw.display_name.presence || uw.slack_user_id}"
    end

    def invite_all
      @workspace
        .workspace_users
        .reject(&:connected?)
        .each do |uw|
          send_invite_dm(uw.slack_user_id)
          uw.update!(invited_at: Time.current) # ← and here
        end

      redirect_to workspace_members_path(@workspace),
                  notice: "Invites sent to all missing members"
    end

    private

    def set_workspace
      @workspace = current_user.workspaces.where(archived_at: nil).find(params[:workspace_id])
    end

    def ensure_owner!
      uw = current_user.workspace_users.find_by(workspace: @workspace)
      redirect_to(workspace_path(@workspace), alert: "Access denied") unless uw&.owner?
    end

    # Uses the workspace’s bot token (slack_bot_token) to open a DM and send it
    def send_invite_dm(slack_user_id)
      installer = current_user.workspace_users.find_by(workspace: @workspace)
      bot_token = installer&.slack_bot_token

      unless bot_token.present?
        Rails.logger.error "[Slack DM] no bot token for workspace #{ @workspace.id }, cannot invite"
        return
      end

      svc = Slack::Service.new(bot_token)

      open_res = svc.conversations_open(users: slack_user_id)
      unless open_res['ok']
        Rails.logger.error "[Slack DM] conversations.open failed: #{open_res['error']}"
        return
      end

      channel_id = open_res.dig("channel", "id")
      invite_url = user_slack_sso_omniauth_authorize_url(
        workspace_id: @workspace.id
      )

      inviter    = current_user.full_name || current_user.email

      message_text = <<~MSG
        Hey there! :wave:

        *#{inviter}* invited you to join *Pulse*, our Slack companion that provides helpful insights about your communication.

        Click below to connect your Slack account and get started:
        #{invite_url}

        If you have any questions, let me know!
      MSG

      post_res = svc.chat_postMessage(
        channel: channel_id,
        text:    message_text
      )

      unless post_res['ok']
        Rails.logger.error "[Slack DM] chat.postMessage failed: #{post_res['error']}"
      end
    end
  end
end
