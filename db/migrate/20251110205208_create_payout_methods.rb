class CreatePayoutMethods < ActiveRecord::Migration[7.1]
  def change
    create_table :payout_methods do |t|
      t.references :user, null: false, foreign_key: true
      t.string :method, null: false                # e.g. "paypal", "trolley", "bank_transfer"
      t.jsonb  :details, default: {}               # e.g. { "email": "partner@example.com" }
      t.boolean :is_default, default: false, null: false
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :payout_methods, [:user_id, :method], unique: true
    add_index :payout_methods, [:user_id, :is_default], where: "is_default = true"
  end
end
