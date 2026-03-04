class AddNotesToDetectedSignals < ActiveRecord::Migration[7.1]
  def change
    add_column :detected_signals, :notes, :text
  end
end
