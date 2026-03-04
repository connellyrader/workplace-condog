class CreateSignalDefinitions < ActiveRecord::Migration[7.1]
  def change
    create_table :signal_definitions do |t|
      t.references :framework_subcategory, null: false, foreign_key: true
      t.text :description
      t.decimal :base_score

      t.timestamps
    end
  end
end
