class CutoverLogitMarginEverywhere < ActiveRecord::Migration[7.1]
  def up
    # detections: add margin column, remove ratio column + ratio indexes
    add_column :detections, :logit_margin, :float unless column_exists?(:detections, :logit_margin)

    remove_index :detections, name: :index_detections_on_logit_ratio, if_exists: true
    remove_index :detections, name: :index_detections_on_metric_logit_ratio_partial, if_exists: true
    remove_index :detections, name: :index_detections_on_submetric_logit_ratio_partial, if_exists: true
    remove_index :detections, name: :index_detections_on_signal_category_logit_ratio_partial, if_exists: true

    remove_column :detections, :logit_ratio, :float if column_exists?(:detections, :logit_ratio)

    add_index :detections, :logit_margin, if_not_exists: true
    add_index :detections, [:metric_id, :logit_margin],
              name: :index_detections_on_metric_logit_margin_partial,
              where: "logit_margin IS NOT NULL",
              if_not_exists: true
    add_index :detections, [:submetric_id, :logit_margin],
              name: :index_detections_on_submetric_logit_margin_partial,
              where: "logit_margin IS NOT NULL",
              if_not_exists: true
    add_index :detections, [:signal_category_id, :logit_margin],
              name: :index_detections_on_signal_category_logit_margin_partial,
              where: "logit_margin IS NOT NULL",
              if_not_exists: true

    # message_signal_categories: rename stored strength field to margin semantics
    if table_exists?(:message_signal_categories) &&
       column_exists?(:message_signal_categories, :logit_ratio) &&
       !column_exists?(:message_signal_categories, :logit_margin)
      rename_column :message_signal_categories, :logit_ratio, :logit_margin
    end

    # rollup/pipeline/calibration: rename min-threshold columns to margin semantics
    if table_exists?(:insight_detection_rollups) &&
       column_exists?(:insight_detection_rollups, :logit_ratio_min) &&
       !column_exists?(:insight_detection_rollups, :logit_margin_min)
      rename_column :insight_detection_rollups, :logit_ratio_min, :logit_margin_min
    end

    if table_exists?(:insight_pipeline_runs) &&
       column_exists?(:insight_pipeline_runs, :logit_ratio_min) &&
       !column_exists?(:insight_pipeline_runs, :logit_margin_min)
      rename_column :insight_pipeline_runs, :logit_ratio_min, :logit_margin_min
    end

    if table_exists?(:insight_trigger_calibration_runs) &&
       column_exists?(:insight_trigger_calibration_runs, :logit_ratio_min) &&
       !column_exists?(:insight_trigger_calibration_runs, :logit_margin_min)
      rename_column :insight_trigger_calibration_runs, :logit_ratio_min, :logit_margin_min
    end

    # index names (optional but keeps semantics clean)
    rename_index_if_exists :insight_detection_rollups,
                           :idx_insight_det_rollups_workspace_threshold,
                           :idx_insight_det_rollups_workspace_margin_threshold

    rename_index_if_exists :insight_detection_rollups,
                           :idx_insight_det_rollups_unique,
                           :idx_insight_det_rollups_unique_margin

    rename_index_if_exists :insight_trigger_calibration_runs,
                           :idx_calibration_runs_workspace_logit,
                           :idx_calibration_runs_workspace_margin
  end

  def down
    if table_exists?(:message_signal_categories) &&
       column_exists?(:message_signal_categories, :logit_margin) &&
       !column_exists?(:message_signal_categories, :logit_ratio)
      rename_column :message_signal_categories, :logit_margin, :logit_ratio
    end

    # revert column names
    if table_exists?(:insight_detection_rollups) &&
       column_exists?(:insight_detection_rollups, :logit_margin_min) &&
       !column_exists?(:insight_detection_rollups, :logit_ratio_min)
      rename_column :insight_detection_rollups, :logit_margin_min, :logit_ratio_min
    end

    if table_exists?(:insight_pipeline_runs) &&
       column_exists?(:insight_pipeline_runs, :logit_margin_min) &&
       !column_exists?(:insight_pipeline_runs, :logit_ratio_min)
      rename_column :insight_pipeline_runs, :logit_margin_min, :logit_ratio_min
    end

    if table_exists?(:insight_trigger_calibration_runs) &&
       column_exists?(:insight_trigger_calibration_runs, :logit_margin_min) &&
       !column_exists?(:insight_trigger_calibration_runs, :logit_ratio_min)
      rename_column :insight_trigger_calibration_runs, :logit_margin_min, :logit_ratio_min
    end

    rename_index_if_exists :insight_detection_rollups,
                           :idx_insight_det_rollups_workspace_margin_threshold,
                           :idx_insight_det_rollups_workspace_threshold

    rename_index_if_exists :insight_detection_rollups,
                           :idx_insight_det_rollups_unique_margin,
                           :idx_insight_det_rollups_unique

    rename_index_if_exists :insight_trigger_calibration_runs,
                           :idx_calibration_runs_workspace_margin,
                           :idx_calibration_runs_workspace_logit

    remove_index :detections, name: :index_detections_on_signal_category_logit_margin_partial, if_exists: true
    remove_index :detections, name: :index_detections_on_submetric_logit_margin_partial, if_exists: true
    remove_index :detections, name: :index_detections_on_metric_logit_margin_partial, if_exists: true
    remove_index :detections, :logit_margin, if_exists: true

    add_column :detections, :logit_ratio, :float unless column_exists?(:detections, :logit_ratio)
    remove_column :detections, :logit_margin, :float if column_exists?(:detections, :logit_margin)

    add_index :detections, :logit_ratio, if_not_exists: true
    add_index :detections, [:metric_id, :logit_ratio],
              name: :index_detections_on_metric_logit_ratio_partial,
              where: "logit_ratio IS NOT NULL",
              if_not_exists: true
    add_index :detections, [:submetric_id, :logit_ratio],
              name: :index_detections_on_submetric_logit_ratio_partial,
              where: "logit_ratio IS NOT NULL",
              if_not_exists: true
    add_index :detections, [:signal_category_id, :logit_ratio],
              name: :index_detections_on_signal_category_logit_ratio_partial,
              where: "logit_ratio IS NOT NULL",
              if_not_exists: true
  end

  private

  def rename_index_if_exists(_table, old_name, new_name)
    return unless pg_index_exists?(old_name)
    return if pg_index_exists?(new_name)

    execute("ALTER INDEX #{quote_table_name(old_name)} RENAME TO #{quote_column_name(new_name)}")
  end

  def pg_index_exists?(index_name)
    sql = <<~SQL
      SELECT 1
      FROM pg_indexes
      WHERE schemaname = ANY (current_schemas(false))
        AND indexname = #{connection.quote(index_name)}
      LIMIT 1
    SQL
    connection.select_value(sql).present?
  end
end
