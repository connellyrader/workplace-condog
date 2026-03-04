class CreateWorkspaceUsersJoinTable < ActiveRecord::Migration[7.1]
  def change
    create_table :workspace_users do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user,      null: false, foreign_key: true
      t.boolean    :is_owner,  null: false, default: false
      t.string     :role

      t.timestamps
    end

    add_index :workspace_users, [:workspace_id, :user_id], unique: true
  end
end
