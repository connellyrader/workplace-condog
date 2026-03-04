class AddHistoryAndMetaToChannels < ActiveRecord::Migration[7.1]
  def change
    change_table :channels, bulk: true do |t|
      t.string  :kind, null: false, default: "public_channel" # public_channel|private_channel|im|mpim
      t.boolean :is_archived, null: false, default: false
      t.boolean :is_shared,   null: false, default: false
      t.bigint  :created_unix

      # Backfill + audit state
      t.decimal :backfill_anchor_latest_ts, precision: 16, scale: 6
      t.decimal :backfill_next_oldest_ts,  precision: 16, scale: 6
      t.integer :backfill_window_days, null: false, default: 7
      t.boolean :backfill_complete,    null: false, default: false
      t.decimal :forward_newest_ts, precision: 16, scale: 6
      t.datetime :last_audit_at
      t.string   :last_history_status
      t.text     :last_history_error
    end

    add_index :channels, :kind

    create_table :channel_memberships do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :channel,   null: false, foreign_key: true
      t.references :workspace_user, null: false, foreign_key: true
      t.datetime :joined_at
      t.datetime :left_at
      t.timestamps
    end
    add_index :channel_memberships, [:channel_id, :workspace_user_id], unique: true

    change_table :messages, bulk: true do |t|
      t.string  :slack_thread_ts
      t.string  :subtype
      t.jsonb   :raw, default: {}
      t.datetime :edited_at
      t.boolean :deleted, null: false, default: false
    end
    add_index :messages, :slack_thread_ts

    change_table :workspace_users, bulk: true do |t|
      t.datetime :channels_last_synced_at
      t.datetime :rate_limited_until
      t.integer  :rate_limit_last_retry_after_seconds
      t.datetime :profile_refreshed_at
    end

  end
end
