class CreateInsightRollupTables < ActiveRecord::Migration[7.1]
  def change
    create_table :insight_detection_rollups do |t|
      t.bigint  :workspace_id,    null: false
      t.string  :subject_type,    null: false
      t.bigint  :subject_id,      null: false
      t.string  :dimension_type,  null: false
      t.bigint  :dimension_id,    null: false
      t.bigint  :metric_id
      t.date    :posted_on,       null: false
      t.decimal :logit_ratio_min, precision: 10, scale: 4, null: false, default: 0
      t.integer :total_count,     null: false, default: 0
      t.integer :positive_count,  null: false, default: 0
      t.integer :negative_count,  null: false, default: 0
      t.timestamps
    end

    add_index :insight_detection_rollups,
              [:workspace_id, :subject_type, :subject_id, :dimension_type, :dimension_id, :logit_ratio_min, :posted_on],
              unique: true,
              name: "idx_insight_det_rollups_unique"
    add_index :insight_detection_rollups, [:workspace_id, :posted_on], name: "idx_insight_det_rollups_workspace_day"
    add_index :insight_detection_rollups, [:workspace_id, :logit_ratio_min], name: "idx_insight_det_rollups_workspace_threshold"

    create_table :insight_simulation_runs do |t|
      t.string  :name
      t.bigint  :workspace_id,       null: false
      t.datetime :snapshot_at,       null: false
      t.integer :window_days,        null: false
      t.integer :baseline_days,      null: false
      t.integer :window_offset_days, null: false, default: 0
      t.decimal :logit_ratio_min,    precision: 10, scale: 4, null: false, default: 0
      t.string  :direction,          null: false, default: "negative"
      t.integer :min_window_detections
      t.integer :min_baseline_detections
      t.decimal :min_current_rate,   precision: 10, scale: 4
      t.decimal :min_delta_rate,     precision: 10, scale: 4
      t.decimal :min_z_score,        precision: 10, scale: 4
      t.decimal :min_window_expected_fraction, precision: 10, scale: 4
      t.integer :window_floor_override
      t.integer :baseline_floor_override
      t.string  :subject_scope
      t.string  :dimension_type
      t.integer :top_n
      t.integer :total_candidates
      t.integer :fired_candidates
      t.decimal :fire_rate, precision: 10, scale: 4
      t.jsonb   :params,  null: false, default: {}
      t.jsonb   :results, null: false, default: {}
      t.timestamps
    end

    add_index :insight_simulation_runs, [:workspace_id, :snapshot_at], name: "idx_insight_sim_runs_workspace_snapshot"
  end
end
