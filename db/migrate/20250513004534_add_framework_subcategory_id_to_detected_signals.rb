class AddFrameworkSubcategoryIdToDetectedSignals < ActiveRecord::Migration[7.1]
  def change
    add_reference :detected_signals, :framework_subcategory, null: true, foreign_key: true
  end
end
