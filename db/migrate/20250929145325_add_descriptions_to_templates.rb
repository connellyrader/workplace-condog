class AddDescriptionsToTemplates < ActiveRecord::Migration[7.1]
  def change
    add_column :templates, :positive_description, :text
    add_column :templates, :negative_description, :text
  end
end
