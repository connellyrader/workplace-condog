class AddTextPurgedAtToMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :messages, :text_purged_at, :datetime
    add_index  :messages, :text_purged_at
  end
end
