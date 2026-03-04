class CreateChannelIdentities < ActiveRecord::Migration[7.0]
  def change
    create_table :channel_identities do |t|
      t.references :integration, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.references :integration_user, foreign_key: true
      t.string :provider, null: false
      t.string :external_channel_id, null: false
      t.datetime :discovered_at
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :channel_identities,
              [:integration_id, :provider, :external_channel_id],
              unique: true,
              name: "idx_channel_identities_on_integration_provider_extid"
  end
end
