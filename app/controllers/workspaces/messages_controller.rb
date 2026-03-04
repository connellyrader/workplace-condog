# app/controllers/workspaces/messages_controller.rb
module Workspaces
  class MessagesController < ApplicationController
    before_action :authenticate_user!
    before_action :set_workspace

    # GET /workspaces/:workspace_id/messages
    def index
      # find your join‐row
      user_ws = current_user.workspace_users.find_by(workspace: @workspace)

      if user_ws&.owner?
        @channels = @workspace.channels
      else
        # only channels where *you* have messages
        @channels = @workspace.channels
                             .joins(:messages)
                             .where(messages: { workspace_user_id: user_ws.id })
                             .distinct
                             .includes(messages: { workspace_user: :user })
      end
    end

    private

    def set_workspace
      @workspace = current_user.workspaces.where(archived_at: nil).find(params[:workspace_id])
    end
  end
end
