class AddTimeStampsToMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :messages, :sent_for_inference_at, :datetime
    add_column :messages, :processed_at, :datetime
    add_index  :messages, :sent_for_inference_at
    add_index  :messages, :processed_at
  end
end
