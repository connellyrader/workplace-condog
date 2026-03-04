# db/migrate/20251211120000_create_workspace_invites.rb
class CreateWorkspaceInvites < ActiveRecord::Migration[7.1]
  def change
    create_table :workspace_invites do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :integration_user, null: false, foreign_key: true
      t.references :invited_by, null: false, foreign_key: { to_table: :users }

      t.string :email, null: false
      t.string :name
      t.string :role, null: false, default: "user"      # "owner", "admin", "viewer", "user"
      t.string :status, null: false, default: "pending" # pending/accepted/canceled/expired
      t.string :token, null: false

      t.datetime :accepted_at
      t.datetime :expires_at

      t.timestamps
    end

    add_index :workspace_invites,
              [:workspace_id, :integration_user_id],
              unique: true,
              name: "index_workspace_invites_on_workspace_and_integration_user"

    add_index :workspace_invites, :token, unique: true
  end
end
