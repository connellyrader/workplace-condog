class CreateInsightTriggerTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :insight_trigger_templates do |t|
      t.string  :key,           null: false
      t.string  :driver_type,   null: false
      t.string  :name,          null: false
      t.text    :description

      t.text    :subject_scopes, null: false, default: ""
      t.string  :dimension_type, null: false
      t.string  :direction
      t.boolean :primary, null: false, default: true

      t.integer :window_days
      t.integer :baseline_days
      t.integer :window_offset_days, null: false, default: 0

      t.integer :min_window_detections
      t.integer :min_baseline_detections
      t.decimal :min_current_rate, precision: 10, scale: 4
      t.decimal :min_delta_rate,   precision: 10, scale: 4
      t.decimal :min_z_score,      precision: 10, scale: 4

      t.decimal :severity_weight, precision: 10, scale: 4
      t.integer :cooldown_days
      t.integer :max_per_subject_per_window

      t.text   :system_prompt
      t.jsonb  :metadata, null: false, default: {}

      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :insight_trigger_templates, :key, unique: true
    add_index :insight_trigger_templates, :enabled

    add_reference :insights,
                  :trigger_template,
                  foreign_key: { to_table: :insight_trigger_templates }
  end
end
