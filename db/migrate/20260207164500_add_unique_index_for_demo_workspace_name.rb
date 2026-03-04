# frozen_string_literal: true

class AddUniqueIndexForDemoWorkspaceName < ActiveRecord::Migration[7.1]
  def change
    # Prevent races creating multiple "Demo Workspace" rows.
    # Keep scope narrow to avoid changing behavior for normal workspaces.
    add_index :workspaces,
              :name,
              unique: true,
              where: "name = 'Demo Workspace'",
              name: "uniq_workspaces_demo_workspace_name"
  end
end
