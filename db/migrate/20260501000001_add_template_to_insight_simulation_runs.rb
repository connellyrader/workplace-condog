class AddTemplateToInsightSimulationRuns < ActiveRecord::Migration[7.1]
  def change
    change_table :insight_simulation_runs, bulk: true do |t|
      t.string :baseline_mode
      t.references :trigger_template, foreign_key: { to_table: :insight_trigger_templates }
      t.string :trigger_key
      t.string :driver_type
    end
  end
end
