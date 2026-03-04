# db/migrate/20251215xxxxxx_add_archived_at_to_workspaces.rb
class AddArchivedAtToWorkspaces < ActiveRecord::Migration[7.1]
  def change
    add_column :workspaces, :archived_at, :datetime
    add_index  :workspaces, :archived_at
  end
end
