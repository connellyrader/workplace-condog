class RemoveDescriptionFieldsFromInsightTriggerTemplates < ActiveRecord::Migration[7.1]
  def change
    remove_column :insight_trigger_templates, :window_days_description, :text
    remove_column :insight_trigger_templates, :baseline_days_description, :text
    remove_column :insight_trigger_templates, :window_offset_days_description, :text
    remove_column :insight_trigger_templates, :min_window_detections_description, :text
    remove_column :insight_trigger_templates, :min_baseline_detections_description, :text
    remove_column :insight_trigger_templates, :min_current_rate_description, :text
    remove_column :insight_trigger_templates, :min_delta_rate_description, :text
    remove_column :insight_trigger_templates, :min_z_score_description, :text
    remove_column :insight_trigger_templates, :severity_weight_description, :text
    remove_column :insight_trigger_templates, :cooldown_days_description, :text
    remove_column :insight_trigger_templates, :max_per_subject_per_window_description, :text
  end
end
