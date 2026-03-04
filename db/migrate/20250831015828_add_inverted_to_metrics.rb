class AddInvertedToMetrics < ActiveRecord::Migration[7.1]
  def change
    add_column :metrics, :reverse, :boolean, default: false
    add_column :metrics, :sort, :integer
  end
end
