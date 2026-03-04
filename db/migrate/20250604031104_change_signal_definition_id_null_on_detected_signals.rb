class ChangeSignalDefinitionIdNullOnDetectedSignals < ActiveRecord::Migration[7.1]
  def change
    change_column_null :detected_signals, :signal_definition_id, true
    change_column_null :detected_signals, :framework_subcategory_id, true
  end
end
