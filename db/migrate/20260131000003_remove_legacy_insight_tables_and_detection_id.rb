class RemoveLegacyInsightTablesAndDetectionId < ActiveRecord::Migration[7.1]
  def change
    drop_table :insight_trigger_calibration_results, if_exists: true
    drop_table :insight_trigger_calibration_runs, if_exists: true
    drop_table :insight_simulation_runs, if_exists: true
    drop_table :insight_feedback, if_exists: true
    drop_table :insight_views, if_exists: true

    remove_index :insights, :detection_id, if_exists: true
    remove_column :insights, :detection_id, :bigint
  end
end
