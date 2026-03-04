class RenamePersistedOnInsightPipelineRuns < ActiveRecord::Migration[7.1]
  def change
    rename_column :insight_pipeline_runs, :persisted, :persisted_count
  end
end
