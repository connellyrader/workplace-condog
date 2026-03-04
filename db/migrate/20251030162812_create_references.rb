class CreateReferences < ActiveRecord::Migration[7.1]
  def up
    enable_extension "pg_trgm" unless extension_enabled?("pg_trgm")

    # references: just kind + value (global, channel-agnostic)
    create_table :references do |t|
      t.string :kind,  null: false   # project | event | doc | deal | code_link | meeting_link | generic_link | id_token | topic
      t.string :value, null: false   # normalized string (url, token, hashtag, title, etc.)
      t.timestamps
    end
    add_index :references, [:kind, :value], unique: true, name: "uniq_references_kind_value"
    execute 'CREATE INDEX idx_references_value_trgm ON "references" USING gin (value gin_trgm_ops);'

    # join table: message_id ↔ reference_id
    create_table :reference_mentions do |t|
      t.bigint :message_id,   null: false
      t.bigint :reference_id, null: false
      t.timestamps
    end
    add_foreign_key :reference_mentions, :messages,   column: :message_id,   on_delete: :cascade
    add_foreign_key :reference_mentions, :references, column: :reference_id, on_delete: :cascade
    add_index :reference_mentions, :message_id
    add_index :reference_mentions, :reference_id
    add_index :reference_mentions, [:message_id, :reference_id], unique: true, name: "uniq_reference_mentions_msgid_ref"

    # messages flags so cron can skip already-processed rows
    add_column :messages, :references_processed,    :boolean,  null: false, default: false
    add_column :messages, :references_processed_at, :datetime
    add_index  :messages, :references_processed
  end

  def down
    remove_index  :messages, :references_processed
    remove_column :messages, :references_processed_at
    remove_column :messages, :references_processed

    remove_index  :reference_mentions, name: "uniq_reference_mentions_msgid_ref"
    remove_index  :reference_mentions, :reference_id
    remove_index  :reference_mentions, :message_id
    remove_foreign_key :reference_mentions, column: :reference_id
    remove_foreign_key :reference_mentions, column: :message_id
    drop_table :reference_mentions

    execute 'DROP INDEX IF EXISTS idx_references_value_trgm;'
    remove_index :references, name: "uniq_references_kind_value"
    drop_table :references
  end
end
