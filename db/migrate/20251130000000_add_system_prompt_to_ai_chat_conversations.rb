class AddSystemPromptToAiChatConversations < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_chat_conversations, :system_prompt, :text
  end
end
