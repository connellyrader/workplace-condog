class RemoveInsightProcessedFromDetections < ActiveRecord::Migration[7.0]
  def change
    remove_index :detections, :insight_processed if index_exists?(:detections, :insight_processed)
    remove_column :detections, :insight_processed, :boolean
  end
end
