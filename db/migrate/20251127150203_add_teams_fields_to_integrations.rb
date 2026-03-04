class AddTeamsFieldsToIntegrations < ActiveRecord::Migration[7.1]
  def change
    add_column :integrations, :ms_tenant_id, :string
    add_column :integrations, :ms_display_name, :string
    add_column :integrations, :ms_access_token, :text
    add_column :integrations, :ms_refresh_token, :text
    add_column :integrations, :ms_expires_at, :datetime
  end
end
