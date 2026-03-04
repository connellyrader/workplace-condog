class CreateNotificationSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :notification_preferences do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.boolean :email_enabled
      t.boolean :slack_enabled
      t.boolean :teams_enabled

      t.boolean :personal_insights_enabled
      t.boolean :all_group_insights_enabled
      t.boolean :my_group_insights_enabled
      t.boolean :executive_summaries_enabled

      t.timestamps
    end

    add_index :notification_preferences, [:workspace_id, :user_id], unique: true

    create_table :workspace_notification_permissions do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :account_type, null: false
      t.boolean :enabled, null: false, default: true
      t.text :allowed_types, array: true, default: []

      t.timestamps
    end

    add_index :workspace_notification_permissions, [:workspace_id, :account_type], unique: true, name: "index_notification_permissions_on_workspace_and_account_type"
  end
end
