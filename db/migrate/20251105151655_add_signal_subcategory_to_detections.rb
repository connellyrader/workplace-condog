class AddSignalSubcategoryToDetections < ActiveRecord::Migration[7.1]
  def change
    add_column :detections, :metric_id, :integer, null: true
    add_column :detections, :submetric_id, :integer, null: true
    add_column :detections, :signal_subcategory_id, :integer, null: true

    add_index :detections, :metric_id 
    add_index :detections, :submetric_id 
    add_index :detections, :signal_subcategory_id 
  end
end
