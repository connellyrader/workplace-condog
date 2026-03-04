class ChangeDefaultBackfillWindowDaysOnChannels < ActiveRecord::Migration[7.1]
  def change
   change_column_default :channels,
                         :backfill_window_days,
                         from: 7,
                         to: 30
 end
end
