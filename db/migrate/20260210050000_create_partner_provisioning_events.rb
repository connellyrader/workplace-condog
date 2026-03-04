class CreatePartnerProvisioningEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :partner_provisioning_events do |t|
      t.string  :contact_id, null: false
      t.string  :email
      t.bigint  :user_id
      t.string  :status, null: false, default: "received" # received|processed|skipped|failed
      t.jsonb   :payload, null: false, default: {}
      t.text    :error
      t.datetime :processed_at

      t.timestamps
    end

    add_index :partner_provisioning_events, :contact_id, unique: true
    add_index :partner_provisioning_events, :status
    add_index :partner_provisioning_events, :user_id
  end
end
