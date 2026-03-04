class AddWorkspaceToAiChatConversations < ActiveRecord::Migration[7.1]
  def up
    add_reference :ai_chat_conversations, :workspace, null: true, foreign_key: true

    AiChat::Conversation.reset_column_information

    AiChat::Conversation.includes(:user).find_each do |conversation|
      next if conversation.workspace_id.present?

      workspace =
        conversation.user.workspaces.where(archived_at: nil).order(:created_at).first ||
        conversation.user.workspaces.order(:created_at).first

      # Fall back to creating a workspace so existing conversations stay reachable.
      unless workspace
        raw_name     = conversation.user.full_name.to_s
        safe_name    = raw_name.gsub(/[^[:alnum:]\s\-\&\._']/, "").strip
        workspace_name = safe_name.presence || "Workspace #{conversation.user.id}"
        workspace_name = workspace_name[0, 60]

        workspace = Workspace.create!(
          name: workspace_name,
          owner: conversation.user
        )

        WorkspaceUser.create!(
          workspace: workspace,
          user: conversation.user,
          is_owner: true,
          role: "owner"
        )
      end

      conversation.update_columns(workspace_id: workspace.id)
    end

    change_column_null :ai_chat_conversations, :workspace_id, false
    add_index :ai_chat_conversations, [:workspace_id, :user_id, :last_activity_at], name: "idx_ai_chat_conversations_ws_user_activity"
  end

  def down
    remove_index :ai_chat_conversations, name: "idx_ai_chat_conversations_ws_user_activity"
    remove_reference :ai_chat_conversations, :workspace, foreign_key: true
  end
end
