class CreateChannels < ActiveRecord::Migration[7.1]
  def change
    create_table :channels do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :slack_channel_id, null: false  # e.g. "C123ABC"
      t.string :name
      t.boolean :is_private, default: false
      t.timestamps
    end

    add_index :channels, [:workspace_id, :slack_channel_id], unique: true

  end
end
