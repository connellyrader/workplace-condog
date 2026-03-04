class AddRangeToClaraOverviews < ActiveRecord::Migration[7.1]
  def change
    add_column :clara_overviews, :range_start, :date
    add_column :clara_overviews, :range_end,   :date

    add_index :clara_overviews,
              [:workspace_id, :metric_id, :range_start, :range_end, :created_at],
              name: "index_clara_overviews_on_ws_metric_range_created_at"
  end
end
