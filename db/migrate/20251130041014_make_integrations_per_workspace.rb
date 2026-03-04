class MakeIntegrationsPerWorkspace < ActiveRecord::Migration[7.1]
  def change
    # 1) Slack: was globally unique on slack_team_id
    remove_index :integrations, name: "index_integrations_on_slack_team_id"

    add_index :integrations,
              [:slack_team_id, :workspace_id],
              unique: true,
              name: "index_integrations_on_slack_team_and_workspace"

    # 2) Teams: optional, but helpful for queries
    # (not unique today, so nothing to remove)
    add_index :integrations,
              [:ms_tenant_id, :workspace_id],
              name: "index_integrations_on_ms_tenant_and_workspace"
  end
end
