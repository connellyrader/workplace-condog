class CreateDetectedSignals < ActiveRecord::Migration[7.1]
  def change
    create_table :detected_signals do |t|
      t.references :signal_definition, null: false, foreign_key: true
      t.references :subcategory, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true
      t.text :text
      t.string :confidence
      t.decimal :adjusted_score

      t.timestamps
    end
  end
end
