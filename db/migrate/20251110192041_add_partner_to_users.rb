class AddPartnerToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :partner, :boolean
  end
end
