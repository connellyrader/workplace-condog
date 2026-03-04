class AddDescriptionToMetrics < ActiveRecord::Migration[7.1]
  def change
    add_column :metrics, :description, :string
  end
end
