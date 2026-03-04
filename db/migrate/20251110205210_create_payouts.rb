class CreatePayouts < ActiveRecord::Migration[7.1]
  def change
    create_table :payouts do |t|
      t.references :user, null: false, foreign_key: true          # Affiliate being paid
      t.references :payout_method, foreign_key: true              # e.g., PayPal, Trolley, etc.

      t.integer  :amount, null: false                             # Total payout amount (in cents)
      t.date     :start_date, null: false                         # Earnings window: start
      t.date     :end_date, null: false                           # Earnings window: end
      t.datetime :paid_at                                         # When payout was processed

      t.string   :external_id                                     # e.g., Trolley payout ID
      t.string   :status, default: "pending"                      # pending, paid, failed, etc.

      t.timestamps
    end

    add_index :payouts, [:user_id, :start_date, :end_date], unique: true
  end
end
