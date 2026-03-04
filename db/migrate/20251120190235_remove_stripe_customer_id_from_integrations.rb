class RemoveStripeCustomerIdFromIntegrations < ActiveRecord::Migration[7.1]
  def change
    remove_column :integrations, :stripe_customer_id, :string
  end
end
