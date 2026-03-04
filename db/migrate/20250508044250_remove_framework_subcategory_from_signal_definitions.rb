class RemoveFrameworkSubcategoryFromSignalDefinitions < ActiveRecord::Migration[7.1]
  def change
    remove_reference :signal_definitions, :framework_subcategory, foreign_key: true, index: true
  end
end
