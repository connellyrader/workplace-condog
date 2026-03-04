class AddProcessedToMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :messages, :processed, :boolean, default: false, null: false
    add_index :messages, :processed
  end
end
