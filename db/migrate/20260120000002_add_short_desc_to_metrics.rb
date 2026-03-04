class AddShortDescToMetrics < ActiveRecord::Migration[7.1]
  def change
    add_column :metrics, :short_description, :string
  end
end
