class CreateFrameworks < ActiveRecord::Migration[7.1]
  def change
    create_table :frameworks do |t|
      t.string :name

      t.timestamps
    end
    add_index :frameworks, :name
  end
end
