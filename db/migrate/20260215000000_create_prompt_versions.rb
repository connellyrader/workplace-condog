class CreatePromptVersions < ActiveRecord::Migration[7.0]
  def change
    create_table :prompt_versions do |t|
      t.string  :key, null: false
      t.integer :version, null: false, default: 1
      t.string  :label
      t.text    :content, null: false
      t.boolean :active, null: false, default: false
      t.references :created_by, foreign_key: { to_table: :users }
      t.jsonb   :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :prompt_versions, [:key, :version], unique: true
    add_index :prompt_versions, :key
    add_index :prompt_versions, [:key], name: "idx_prompt_versions_unique_active", unique: true, where: "active"

    add_column :ai_chat_conversations, :purpose, :string
    add_index  :ai_chat_conversations, :purpose
    add_index  :ai_chat_conversations, [:user_id, :purpose, :last_activity_at], name: "idx_ai_chat_conv_user_purpose_activity"
  end
end
