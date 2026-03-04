class AddDescriptionToSignalSubcategories < ActiveRecord::Migration[7.1]
  def change
    add_column :signal_subcategories, :description, :string
  end
end
