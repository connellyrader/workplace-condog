class AddActiveToWorkspaceUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :workspace_users, :active, :boolean, default: true, null: false
    add_index  :workspace_users, :active
  end
end
