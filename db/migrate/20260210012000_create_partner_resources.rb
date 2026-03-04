class CreatePartnerResources < ActiveRecord::Migration[7.0]
  def change
    create_table :partner_resources do |t|
      t.string  :category, null: false
      t.string  :title,    null: false
      t.string  :url,      null: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :partner_resources, :category
  end
end
