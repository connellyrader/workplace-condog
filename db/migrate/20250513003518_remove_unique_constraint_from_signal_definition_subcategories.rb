class RemoveUniqueConstraintFromSignalDefinitionSubcategories < ActiveRecord::Migration[7.1]
  def up
    remove_index :signal_definition_subcategories, name: "index_signal_defs_subcats_on_def_and_subcat"
    remove_index :signal_definition_framework_subcategories, name: "index_signal_defs_fw_subcats_on_def_and_fw_subcat"
  end

  def down
    add_index :signal_definition_subcategories, [:signal_definition_id, :subcategory_id],
              unique: true, name: "index_signal_defs_subcats_on_def_and_subcat"
    add_index :signal_definition_framework_subcategories, [:signal_definition_id, :framework_subcategory_id],
              unique: true, name: "index_signal_defs_fw_subcats_on_def_and_fw_subcat"
  end
end
