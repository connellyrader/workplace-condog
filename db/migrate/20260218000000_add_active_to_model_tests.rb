class AddActiveToModelTests < ActiveRecord::Migration[7.1]
  def up
    add_column :model_tests, :active, :boolean, null: false, default: false

    add_index :model_tests,
              :active,
              unique: true,
              where: "active",
              name: "index_model_tests_on_active_true"
  end

  def down
    remove_index :model_tests, name: "index_model_tests_on_active_true", if_exists: true
    remove_column :model_tests, :active, if_exists: true
  end
end
