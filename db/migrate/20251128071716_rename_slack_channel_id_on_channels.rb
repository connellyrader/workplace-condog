class RenameSlackChannelIdOnChannels < ActiveRecord::Migration[7.1]
  def up
    # Drop old index that references slack_channel_id
    remove_index :channels, name: "index_channels_on_integration_id_and_slack_channel_id"

    # Rename column
    rename_column :channels, :slack_channel_id, :external_channel_id

    # Recreate unique index on new column name
    add_index :channels,
              [:integration_id, :external_channel_id],
              unique: true,
              name: "index_channels_on_integration_id_and_external_channel_id"
  end

  def down
    remove_index :channels, name: "index_channels_on_integration_id_and_external_channel_id"
    rename_column :channels, :external_channel_id, :slack_channel_id
    add_index :channels,
              [:integration_id, :slack_channel_id],
              unique: true,
              name: "index_channels_on_integration_id_and_slack_channel_id"
  end
end
