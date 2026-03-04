class CreateInsightTriggerCalibrations < ActiveRecord::Migration[7.1]
  def change
    create_table :insight_trigger_calibration_runs do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :trigger_template, null: false, foreign_key: { to_table: :insight_trigger_templates }
      t.datetime :snapshot_at, null: false
      t.decimal :logit_ratio_min, precision: 10, scale: 4, null: false, default: 0
      t.string :baseline_modes, array: true, default: []
      t.decimal :target_fire_rate, precision: 10, scale: 4
      t.decimal :target_tolerance, precision: 10, scale: 4
      t.decimal :overfire_weight, precision: 10, scale: 4
      t.decimal :underfire_weight, precision: 10, scale: 4
      t.jsonb :search_space, null: false, default: {}
      t.jsonb :objective, null: false, default: {}
      t.jsonb :recommended_params, default: {}
      t.jsonb :recommended_metrics, default: {}
      t.integer :param_set_count
      t.timestamps
    end

    add_index :insight_trigger_calibration_runs, [:workspace_id, :logit_ratio_min, :created_at], name: "idx_calibration_runs_workspace_logit"

    create_table :insight_trigger_calibration_results do |t|
      t.references :calibration_run, null: false, foreign_key: { to_table: :insight_trigger_calibration_runs }
      t.jsonb :params, null: false, default: {}
      t.jsonb :metrics, null: false, default: {}
      t.timestamps
    end
  end
end
