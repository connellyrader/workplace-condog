class AddAnalyzedFirst30 < ActiveRecord::Migration[7.1]
  def change
    add_column :workspaces, :analyze_complete, :boolean, null: false, default: false
    add_column :workspaces, :days_analyzed, :integer, null: false, default: 0
  end
end
