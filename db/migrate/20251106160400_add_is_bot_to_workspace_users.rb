class AddIsBotToWorkspaceUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :workspace_users, :is_bot, :boolean, default: false, null: false
  end
end
