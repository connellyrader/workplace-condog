class AddIndexesForDashboardPerformance < ActiveRecord::Migration[7.1]
  def change
    # For strong/weak detection filtering (logit_ratio >= 1.25)
    unless index_exists?(:detections, :logit_ratio)
      add_index :detections, :logit_ratio
    end

    # For dashboard queries filtered by workspace_id + posted_at
    unless index_exists?(:messages, [:workspace_id, :posted_at])
      add_index :messages, [:workspace_id, :posted_at]
    end
  end
end
