class CreateLinks < ActiveRecord::Migration[7.1]
  def change
    create_table :links do |t|
      t.references :user, null: false, foreign_key: true
      t.string :code, null: false

      t.timestamps
    end

    add_index :links, :code, unique: true
  end
end
