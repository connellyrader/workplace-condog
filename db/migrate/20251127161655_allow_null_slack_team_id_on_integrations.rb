class AllowNullSlackTeamIdOnIntegrations < ActiveRecord::Migration[7.1]
  def change
    change_column_null :integrations, :slack_team_id, true
  end
end
