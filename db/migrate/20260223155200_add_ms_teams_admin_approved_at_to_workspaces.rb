class AddMsTeamsAdminApprovedAtToWorkspaces < ActiveRecord::Migration[7.1]
  def change
    add_column :workspaces, :ms_teams_admin_approved_at, :datetime
  end
end
