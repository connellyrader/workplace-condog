class RestructureIntegrationsAndIntegrationUsers < ActiveRecord::Migration[7.1]
  def up
    # 0) Drop FKs that currently point to workspaces / workspace_users
    # (do this BEFORE renaming tables)

    # FKs on workspace_id
    remove_foreign_key :channel_memberships, :workspaces
    remove_foreign_key :channels,            :workspaces
    remove_foreign_key :messages,            :workspaces
    remove_foreign_key :groups,              :workspaces
    remove_foreign_key :workspace_users,     :workspaces

    # FKs on workspace_user_id
    remove_foreign_key :channel_memberships, :workspace_users
    remove_foreign_key :messages,            :workspace_users
    remove_foreign_key :group_members,       :workspace_users

    # 1) Rename workspaces -> integrations (Slack-level)
    rename_table :workspaces, :integrations

    # 2) Rename workspace_users -> integration_users
    rename_table :workspace_users, :integration_users

    # 2b) integration_users.workspace_id -> integration_id
    rename_column :integration_users, :workspace_id, :integration_id

    # 3) Rename columns that referenced old workspaces (Slack integration)

    rename_column :channels,            :workspace_id, :integration_id
    rename_column :messages,            :workspace_id, :integration_id
    rename_column :channel_memberships, :workspace_id, :integration_id
    rename_column :model_tests,         :workspace_id, :integration_id

    # groups.workspace_id stays as workspace_id for now
    # (we will repoint it to NEW app workspaces later)

    # 4) Rename columns that referenced workspace_users

    rename_column :channel_memberships, :workspace_user_id, :integration_user_id
    rename_column :messages,            :workspace_user_id, :integration_user_id
    rename_column :group_members,       :workspace_user_id, :integration_user_id

    # 5) (we are intentionally NOT renaming indexes here; can do later if needed)

    # 6) Re-add FKs to new tables/columns

    # channels/messages/channel_memberships/model_tests now point to integrations
    add_foreign_key :channels,            :integrations
    add_foreign_key :messages,            :integrations
    add_foreign_key :channel_memberships, :integrations
    add_foreign_key :model_tests,         :integrations

    # groups.workspace_id currently still refers to the old IDs,
    # but for now we point it at integrations; in the next migration
    # we’ll move it to app-level workspaces.
    add_foreign_key :groups, :integrations, column: :workspace_id

    # integration_users now belongs_to integrations via integration_id
    add_foreign_key :integration_users, :integrations

    # new integration_users FKs
    add_foreign_key :channel_memberships, :integration_users
    add_foreign_key :messages,            :integration_users
    add_foreign_key :group_members,       :integration_users
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
