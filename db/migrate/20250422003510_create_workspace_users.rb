class CreateWorkspaceUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :workspace_users do |t|
      t.references :workspace,      null: false, foreign_key: true
      t.references :user,           foreign_key: true
      t.string     :slack_user_id,  null: false
      t.string     :role,           default: "member"
      t.string     :slack_history_token
      t.string     :slack_bot_token
      t.string     :slack_refresh_token
      t.datetime   :slack_token_expires_at
      t.string     :display_name
      t.string     :real_name
      t.string     :email
      t.string     :avatar_url

      t.timestamps
    end

    add_index :workspace_users,
              [:workspace_id, :slack_user_id],
              unique: true,
              name: "index_ws_users_on_ws_and_slack_id"

    add_index :workspace_users,
              [:workspace_id, :user_id],
              unique: true,
              name: "index_ws_users_on_ws_and_user",
              where: "user_id IS NOT NULL"
  end
end
