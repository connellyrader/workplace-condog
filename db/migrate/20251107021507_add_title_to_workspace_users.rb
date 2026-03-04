class AddTitleToWorkspaceUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :workspace_users, :title, :string
  end
end
