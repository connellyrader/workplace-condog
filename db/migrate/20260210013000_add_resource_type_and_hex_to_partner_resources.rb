class AddResourceTypeAndHexToPartnerResources < ActiveRecord::Migration[7.0]
  def change
    add_column :partner_resources, :resource_type, :string, null: false, default: "file"
    add_column :partner_resources, :hex, :string

    add_index :partner_resources, :resource_type
  end
end
