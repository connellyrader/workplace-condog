class CreateLinkClicks < ActiveRecord::Migration[7.1]
  def change
    create_table :link_clicks do |t|
      t.references :link, null: false, foreign_key: true
      t.references :created_user, foreign_key: { to_table: :users }
      t.string :ip
      t.string :user_agent
      t.string :referrer
      t.timestamps
    end
  end
end
