class AddHistoryUnreachableToChannels < ActiveRecord::Migration[7.1]
  def change
    add_column :channels, :history_unreachable, :boolean, null: false, default: false
    add_index  :channels, :history_unreachable
  end
end
