class AddAppWorkspacesAndMoveBilling < ActiveRecord::Migration[7.1]
  # Use simple classes inside the migration so we don't depend on app models
  class MigrationIntegration      < ApplicationRecord; self.table_name = "integrations";      has_many :integration_users, class_name: "AddAppWorkspacesAndMoveBilling::MigrationIntegrationUser", foreign_key: :integration_id; end
  class MigrationIntegrationUser  < ApplicationRecord; self.table_name = "integration_users"; end
  class MigrationWorkspace        < ApplicationRecord; self.table_name = "workspaces";        end
  class MigrationSubscription     < ApplicationRecord; self.table_name = "subscriptions";     end
  class MigrationGroup            < ApplicationRecord; self.table_name = "groups";            end
  class MigrationUser             < ApplicationRecord; self.table_name = "users";             end

  def up
    # 1) New app-level workspaces table (your product workspaces)
    create_table :workspaces do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false

      # Stripe customer anchor (who pays for this workspace)
      t.string :stripe_customer_id

      t.timestamps
    end

    # 2) Add workspace_id + kind to integrations (old Slack workspaces)
    add_reference :integrations, :workspace, null: true, foreign_key: true
    add_column    :integrations, :kind, :string, null: false, default: "slack"
    add_index     :integrations, :kind

    # 3) Add workspace_id to subscriptions (billing belongs to a workspace)
    add_reference :subscriptions, :workspace, null: true, foreign_key: true

    # 4) Backfill: create one Workspace per Integration and wire things up
    say_with_time "Backfilling app workspaces from integrations" do
      MigrationIntegration.reset_column_information
      MigrationWorkspace.reset_column_information
      MigrationSubscription.reset_column_information
      MigrationGroup.reset_column_information

      MigrationIntegration.find_each do |integration|
        # Heuristic: owner = first real user attached to this integration, or fallback to first user.
        owner_id =
          integration.integration_users.where.not(user_id: nil).limit(1).pluck(:user_id).first ||
          MigrationUser.first&.id

        # If truly nobody to own this, skip (or you can raise)
        next unless owner_id

        ws = MigrationWorkspace.create!(
          owner_id: owner_id,
          name: integration.name || integration.domain || "Workspace #{integration.id}",
          stripe_customer_id: integration.stripe_customer_id
        )

        # Link integration -> workspace
        integration.update_columns(workspace_id: ws.id)

        # Link subscriptions (if any) to this workspace using stripe_subscription_id
        if integration.respond_to?(:stripe_subscription_id) && integration.stripe_subscription_id.present?
          MigrationSubscription.where(stripe_subscription_id: integration.stripe_subscription_id)
                               .update_all(workspace_id: ws.id)
        end

        # Move any groups that used to point at this integration into this workspace
        MigrationGroup.where(workspace_id: integration.id).update_all(workspace_id: ws.id)
      end
    end

    # 5) Remove subscription-related columns from integrations
    remove_column :integrations, :stripe_subscription_id,     :string
    remove_column :integrations, :subscription_status,        :string
    remove_column :integrations, :subscription_expires_at,    :datetime
    remove_column :integrations, :stripe_subscription_amount, :integer

    # 6) groups.workspace_id now holds NEW workspace IDs (we updated them above),
    #    so we can safely change the FK to point to app-level workspaces.
    remove_foreign_key :groups, :integrations
    add_foreign_key    :groups, :workspaces, column: :workspace_id

    # 7) Now that every integration has a workspace, you can enforce NOT NULL
    change_column_null :integrations, :workspace_id, false

    # Optional: if you’re confident all subscriptions got a workspace_id, enforce it:
    # change_column_null :subscriptions, :workspace_id, false
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
