class AddAuthProviderToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :auth_provider, :string
    add_index  :users, :auth_provider
  end
end
