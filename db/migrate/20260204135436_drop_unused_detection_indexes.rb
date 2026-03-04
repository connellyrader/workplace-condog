# frozen_string_literal: true

# Drop unused indexes on the detections table.
#
# Analysis from pg_stat_user_indexes showed these indexes have 0 scans
# since stats reset, while consuming ~736 MB of disk/memory.
#
# Dropping them will:
# - Free ~736 MB of RAM for the database buffer cache
# - Speed up INSERT/UPDATE operations on detections
# - Reduce disk I/O
#
class DropUnusedDetectionIndexes < ActiveRecord::Migration[7.1]
  def up
    # These indexes have never been used (0 idx_scan in pg_stat_user_indexes)
    # Total space recovered: ~736 MB

    # 157 MB - never used
    remove_index :detections, name: :index_detections_on_async_inference_result_id, if_exists: true

    # 146 MB - never used
    remove_index :detections, name: :index_detections_on_submetric_id, if_exists: true

    # 145 MB - never used
    remove_index :detections, name: :index_detections_on_model_test_id, if_exists: true

    # 139 MB - never used
    remove_index :detections, name: :index_detections_on_metric_id, if_exists: true

    # 125 MB - never used
    remove_index :detections, name: :index_detections_on_signal_subcategory_id, if_exists: true

    # 13 MB - never used (partial index)
    remove_index :detections, name: :index_detections_on_submetric_logit_ratio_partial, if_exists: true

    # 11 MB - never used (partial index)
    remove_index :detections, name: :index_detections_on_metric_logit_ratio_partial, if_exists: true
  end

  def down
    # Re-create indexes if rollback is needed
    # Note: These will take a while to build on 10M+ rows

    add_index :detections, :async_inference_result_id,
              name: :index_detections_on_async_inference_result_id,
              if_not_exists: true

    add_index :detections, :submetric_id,
              name: :index_detections_on_submetric_id,
              if_not_exists: true

    add_index :detections, :model_test_id,
              name: :index_detections_on_model_test_id,
              if_not_exists: true

    add_index :detections, :metric_id,
              name: :index_detections_on_metric_id,
              if_not_exists: true

    add_index :detections, :signal_subcategory_id,
              name: :index_detections_on_signal_subcategory_id,
              if_not_exists: true

    # Partial indexes - recreate with original conditions if known
    # These may need adjustment based on original index definitions
    add_index :detections, [:submetric_id, :logit_ratio],
              name: :index_detections_on_submetric_logit_ratio_partial,
              where: "logit_ratio IS NOT NULL",
              if_not_exists: true

    add_index :detections, [:metric_id, :logit_ratio],
              name: :index_detections_on_metric_logit_ratio_partial,
              where: "logit_ratio IS NOT NULL",
              if_not_exists: true
  end
end
