class RemoveCandidatesSupportingFromInsightPipelineRuns < ActiveRecord::Migration[7.1]
  def change
    return unless table_exists?(:insight_pipeline_runs)
    return unless column_exists?(:insight_pipeline_runs, :candidates_supporting)

    remove_column :insight_pipeline_runs, :candidates_supporting, :integer
  end
end
