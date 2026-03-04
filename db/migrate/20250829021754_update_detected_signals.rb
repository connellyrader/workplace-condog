class UpdateDetectedSignals < ActiveRecord::Migration[7.1]
  def change
    # Describe the OLD schema here so rollback can recreate it
    drop_table :detected_signals, if_exists: true do |t|
      t.references :signal_definition, null: false, foreign_key: true
      t.references :subcategory,       null: false, foreign_key: true
      t.references :message,           null: false, foreign_key: true
      t.text    :text
      t.string  :confidence
      t.decimal :adjusted_score
      t.timestamps
    end

    # Create the NEW schema (edit this block to whatever you want now)
    create_table :detected_signals do |t|
      # ===== NEW schema =====
      t.references :model, null: false, foreign_key: true
      t.references :signal_indicator, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true
      t.references :async_inference_result, null: false, foreign_key: true
      t.text    :description
      t.integer :score
      t.timestamps
    end
  end
end
