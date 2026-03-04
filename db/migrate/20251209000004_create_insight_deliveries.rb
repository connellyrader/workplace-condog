class CreateInsightDeliveries < ActiveRecord::Migration[7.0]
  def change
    create_table :insight_deliveries do |t|
      t.references :insight, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :channel, null: false
      t.string :status, null: false, default: "pending"
      t.string :provider_message_id
      t.jsonb :metadata, null: false, default: {}
      t.text :error_message
      t.datetime :delivered_at

      t.timestamps
    end

    add_index :insight_deliveries, [:insight_id, :channel, :user_id], name: "index_insight_deliveries_on_insight_channel_user"
  end
end
