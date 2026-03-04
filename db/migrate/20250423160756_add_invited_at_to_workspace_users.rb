class AddInvitedAtToWorkspaceUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :workspace_users, :invited_at, :datetime
  end
end
