class AddInsightProcessedToDetections < ActiveRecord::Migration[7.1]
  def change
    add_column :detections, :insight_processed, :boolean, null: false, default: false
    add_index :detections, :insight_processed
  end
end
