class AddSetupStatusToIntegrations < ActiveRecord::Migration[7.1]
  def change
    add_column :integrations, :setup_status, :string, null: false, default: "queued"
    add_column :integrations, :setup_step, :string
    add_column :integrations, :setup_progress, :integer, null: false, default: 0
    add_column :integrations, :setup_error, :text
    add_column :integrations, :setup_started_at, :datetime
    add_column :integrations, :setup_completed_at, :datetime
    add_column :integrations, :setup_channels_count, :integer, null: false, default: 0
    add_column :integrations, :setup_users_count, :integer, null: false, default: 0
    add_column :integrations, :setup_memberships_count, :integer, null: false, default: 0

    add_index :integrations, :setup_status
  end
end
