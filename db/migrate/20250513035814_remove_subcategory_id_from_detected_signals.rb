class RemoveSubcategoryIdFromDetectedSignals < ActiveRecord::Migration[7.1]
  def change
    remove_reference :detected_signals, :subcategory, foreign_key: true

  end
end
