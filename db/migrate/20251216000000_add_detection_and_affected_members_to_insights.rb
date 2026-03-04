class AddDetectionAndAffectedMembersToInsights < ActiveRecord::Migration[7.1]
  def change
    add_reference :insights, :detection, foreign_key: true
    add_column :insights, :affected_members, :jsonb, null: false, default: []
    add_column :insights, :affected_members_captured_at, :datetime

    add_index :insights, :affected_members_captured_at
  end
end
