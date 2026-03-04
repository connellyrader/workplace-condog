class CreateFrameworkSubcategories < ActiveRecord::Migration[7.1]
  def change
    create_table :framework_subcategories do |t|
      t.references :framework, null: false, foreign_key: true
      t.string :name

      t.timestamps
    end
    add_index :framework_subcategories, :name
  end
end
