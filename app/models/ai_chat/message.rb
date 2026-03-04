# app/models/ai_chat/message.rb
class AiChat::Message < ApplicationRecord
  encrypts :content

  self.table_name = "ai_chat_messages"

  belongs_to :conversation, class_name: "AiChat::Conversation", foreign_key: :ai_chat_conversation_id
  validates :role, inclusion: { in: %w[user assistant] }
  validates :content, presence: true
end
