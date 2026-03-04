class AddSyncFieldsToWorkspaces < ActiveRecord::Migration[7.1]
  def change
    add_column :workspaces, :sync_status, :string, null: false, default: "queued"
    add_column :workspaces, :last_synced_at, :datetime
  end
end
