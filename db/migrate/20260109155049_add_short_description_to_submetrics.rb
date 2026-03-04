class AddShortDescriptionToSubmetrics < ActiveRecord::Migration[7.1]
  def change
    add_column :submetrics, :short_description, :string
    add_index  :submetrics, :short_description
  end
end
