class CreateAiChatConversations < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_chat_conversations do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :title, null: false, default: "New conversation"
      t.datetime :last_activity_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end
    add_index :ai_chat_conversations, [:user_id, :last_activity_at]
 
    create_table :ai_chat_messages do |t|
      t.references :ai_chat_conversation, null: false, foreign_key: true, index: { name: "idx_ai_chat_msg_conv" }
      t.string  :role,    null: false # "user" or "assistant"
      t.text    :content, null: false
      t.integer :tokens_in
      t.integer :tokens_out
      t.jsonb   :meta, null: false, default: {}
      t.timestamps
    end
    add_index :ai_chat_messages, [:ai_chat_conversation_id, :created_at], name: "idx_ai_chat_msg_conv_created"
  end
end