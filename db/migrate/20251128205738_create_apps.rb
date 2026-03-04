# db/migrate/20251128120000_create_apps.rb
class CreateApps < ActiveRecord::Migration[7.1]
  def change
    create_table :apps do |t|
      t.string :name,   null: false                 # e.g. "Slack"
      t.text   :description                         # marketing / help text
      t.string :status, null: false, default: "future" # status: "available" or "future"

      t.timestamps
    end

    add_index :apps, :name, unique: true
    add_index :apps, :status
  end
end
