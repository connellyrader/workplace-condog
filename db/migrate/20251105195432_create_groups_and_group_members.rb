class CreateGroupsAndGroupMembers < ActiveRecord::Migration[7.1]
  def change
    create_table :groups do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end

    create_table :group_members do |t|
      t.references :group, null: false, foreign_key: true
      t.references :workspace_user, null: false, foreign_key: true
      t.timestamps
    end

    add_index :group_members, [:group_id, :workspace_user_id], unique: true
  end
end
