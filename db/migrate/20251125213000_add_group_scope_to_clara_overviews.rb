class AddGroupScopeToClaraOverviews < ActiveRecord::Migration[7.1]
  def change
    add_column :clara_overviews, :group_scope, :string

    add_index :clara_overviews,
              [:workspace_id, :metric_id, :range_start, :range_end, :group_scope, :created_at],
              name: "index_clara_overviews_on_ws_metric_range_group_scope"
  end
end
