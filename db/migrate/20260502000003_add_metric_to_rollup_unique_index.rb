class AddMetricToRollupUniqueIndex < ActiveRecord::Migration[7.1]
  def change
    remove_index :insight_detection_rollups, name: "idx_insight_det_rollups_unique"
    add_index :insight_detection_rollups,
              [:workspace_id, :subject_type, :subject_id, :dimension_type, :dimension_id, :metric_id, :logit_ratio_min, :posted_on],
              unique: true,
              name: "idx_insight_det_rollups_unique"
  end
end
