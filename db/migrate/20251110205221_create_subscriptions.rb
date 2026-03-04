class CreateSubscriptions < ActiveRecord::Migration[7.1]
  def change
    create_table :subscriptions do |t|
      t.references :user, null: false, foreign_key: true          # The customer

      t.string  :stripe_subscription_id, null: false              # Stripe subscription ID from Stripe
      t.string  :status                                            # trialing, active, canceled, etc.
      t.date    :started_on                                       # Local start date
      t.date    :expires_on                                       # Calculated expiration date
      t.integer :amount, null: false                              # Subscription price in cents
      t.string  :interval                                         # 'month' or 'year'

      t.timestamps
    end

    add_index :subscriptions, :stripe_subscription_id, unique: true
  end
end
