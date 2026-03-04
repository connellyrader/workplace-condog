class CreateSignalDefinitionSubcategories < ActiveRecord::Migration[7.1]
  def change
    create_table :signal_definition_subcategories do |t|
      t.references :signal_definition, null: false, foreign_key: true
      t.references :subcategory, null: false, foreign_key: true

      t.timestamps
    end

    add_index :signal_definition_subcategories, [:signal_definition_id, :subcategory_id], unique: true, name: "index_signal_defs_subcats_on_def_and_subcat"
  end
end
