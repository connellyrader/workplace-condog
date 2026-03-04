class CreateCharges < ActiveRecord::Migration[7.1]
  def change
    create_table :charges do |t|
      t.references :subscription, null: false, foreign_key: true           # Local subscriptions table
      t.string     :stripe_charge_id, null: false                          # Stripe charge ID

      t.integer    :amount,      null: false                               # Total charged (in cents)
      t.integer    :stripe_fee                                              # Stripe fee (in cents)
      t.integer    :commission                                              # Commission owed to affiliate (in cents)

      t.references :affiliate, null: false, foreign_key: { to_table: :users }
      t.references :customer,  foreign_key: { to_table: :users }
      t.references :payout,    foreign_key: true                           # Null = unpaid

      t.timestamps
    end

    add_index :charges, :stripe_charge_id, unique: true
  end
end
