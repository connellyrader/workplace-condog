class AddTeamsTokensToIntegrationUsers < ActiveRecord::Migration[7.1]
  def up
    add_column :integration_users, :ms_access_token,  :text
    add_column :integration_users, :ms_refresh_token, :text
    add_column :integration_users, :ms_expires_at,    :datetime

    # Drop now-unneeded token columns from integrations
    remove_column :integrations, :ms_access_token,  :text
    remove_column :integrations, :ms_refresh_token, :text
    remove_column :integrations, :ms_expires_at,    :datetime
  end

  def down
    # Restore token columns on integrations
    add_column :integrations, :ms_access_token,  :text
    add_column :integrations, :ms_refresh_token, :text
    add_column :integrations, :ms_expires_at,    :datetime

    remove_column :integration_users, :ms_access_token,  :text
    remove_column :integration_users, :ms_refresh_token, :text
    remove_column :integration_users, :ms_expires_at,    :datetime
  end
end
