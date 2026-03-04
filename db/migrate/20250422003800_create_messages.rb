class CreateMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :messages do |t|
      # Who posted it, in this unified join table
      t.references :workspace_user, null: false, foreign_key: true

      # For quick scoping / lookup across a workspace
      t.references :workspace,      null: false, foreign_key: true

      # Which channel it came from
      t.references :channel,        null: false, foreign_key: true

      # Slack’s unique timestamp for the message
      t.string   :slack_ts, null: false

      # When it was posted
      t.datetime :posted_at

      # The text content
      t.text     :text,       null: false

      t.timestamps
    end

    # You still want one message per channel per slack_ts
    add_index :messages, [:channel_id, :slack_ts], unique: true
  end
end
