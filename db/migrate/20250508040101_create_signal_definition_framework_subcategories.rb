class CreateSignalDefinitionFrameworkSubcategories < ActiveRecord::Migration[7.1]
  def change
    create_table :signal_definition_framework_subcategories do |t|
      t.references :signal_definition, null: false, foreign_key: true
      t.references :framework_subcategory, null: false, foreign_key: true

      t.timestamps
    end

    add_index :signal_definition_framework_subcategories, [:signal_definition_id, :framework_subcategory_id], unique: true, name: 'index_signal_defs_fw_subcats_on_def_and_fw_subcat'
  end
end
