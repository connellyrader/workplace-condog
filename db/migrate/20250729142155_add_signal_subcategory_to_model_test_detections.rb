class AddSignalSubcategoryToModelTestDetections < ActiveRecord::Migration[7.1]
  def change
    add_column :model_test_detections, :signal_subcategory_id, :integer
  end
end
