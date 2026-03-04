class AddEstimatedMessageCountToChannels < ActiveRecord::Migration[7.0]
  def change
    add_column :channels, :estimated_message_count, :integer
    add_column :channels, :message_count_estimated_at, :datetime
  end
end
