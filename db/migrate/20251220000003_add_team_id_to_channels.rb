class AddTeamIdToChannels < ActiveRecord::Migration[7.1]
  def change
    add_reference :channels, :team, null: true, foreign_key: true
  end
end
