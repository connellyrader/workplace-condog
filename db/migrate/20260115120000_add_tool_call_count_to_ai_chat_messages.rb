# frozen_string_literal: true

class AddToolCallCountToAiChatMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_chat_messages, :tool_call_count, :integer, null: false, default: 0
  end
end
