class AddWelcomeNotifiedAtToWorkspaces < ActiveRecord::Migration[7.1]
  def change
    add_column :workspaces, :welcome_notified_at, :datetime
    add_index  :workspaces, :welcome_notified_at
  end
end
