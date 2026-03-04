# app/models/ai_chat/conversation.rb
class AiChat::Conversation < ApplicationRecord
  self.table_name = "ai_chat_conversations"

  belongs_to :user
  belongs_to :workspace
  has_many :messages, class_name: "AiChat::Message", foreign_key: :ai_chat_conversation_id, dependent: :destroy

  validates :title, presence: true

  scope :for_workspace, ->(workspace) { workspace ? where(workspace_id: workspace.id) : none }
  scope :recent_first, -> { order(last_activity_at: :desc, updated_at: :desc) }

  def touch_activity!
    update_columns(last_activity_at: Time.current, updated_at: Time.current)
  end
end
