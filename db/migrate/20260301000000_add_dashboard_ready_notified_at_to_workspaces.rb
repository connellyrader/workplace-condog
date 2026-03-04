class AddDashboardReadyNotifiedAtToWorkspaces < ActiveRecord::Migration[7.1]
  def change
    add_column :workspaces, :dashboard_ready_notified_at, :datetime
    add_index  :workspaces, :dashboard_ready_notified_at
  end
end
