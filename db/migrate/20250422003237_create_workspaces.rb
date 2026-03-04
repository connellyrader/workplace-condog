class CreateWorkspaces < ActiveRecord::Migration[7.1]
  def change
    create_table :workspaces do |t|

      t.string :slack_team_id, null: false      # e.g. "T123ABC"
      t.string :name                            # Slack workspace name
      t.string :domain                          # Slack workspace domain (like "myteam")

      # Billing / subscription fields
      t.string :stripe_customer_id
      t.string :stripe_subscription_id
      t.string :subscription_status             # e.g. "active", "past_due"
      t.datetime :subscription_expires_at
      t.integer :stripe_subscription_amount
      # or any other billing fields you need

      t.timestamps
    end

    add_index :workspaces, :slack_team_id, unique: true

  end
end
