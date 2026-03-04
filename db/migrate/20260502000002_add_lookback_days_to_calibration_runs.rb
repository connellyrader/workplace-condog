class AddLookbackDaysToCalibrationRuns < ActiveRecord::Migration[7.1]
  def change
    add_column :insight_trigger_calibration_runs, :lookback_days, :integer
  end
end
