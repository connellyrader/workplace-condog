class RenameErrorsOnInsightPipelineRuns < ActiveRecord::Migration[7.1]
  def change
    rename_column :insight_pipeline_runs, :errors, :error_payload
  end
end
