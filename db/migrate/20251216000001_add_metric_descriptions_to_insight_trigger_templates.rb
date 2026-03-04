class AddMetricDescriptionsToInsightTriggerTemplates < ActiveRecord::Migration[7.1]
  def change
    change_table :insight_trigger_templates, bulk: true do |t|
      t.text :window_days_description
      t.text :baseline_days_description
      t.text :window_offset_days_description
      t.text :min_window_detections_description
      t.text :min_baseline_detections_description
      t.text :min_current_rate_description
      t.text :min_delta_rate_description
      t.text :min_z_score_description
      t.text :severity_weight_description
      t.text :cooldown_days_description
      t.text :max_per_subject_per_window_description
    end
  end
end
