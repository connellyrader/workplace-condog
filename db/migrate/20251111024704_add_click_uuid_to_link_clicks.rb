class AddClickUuidToLinkClicks < ActiveRecord::Migration[7.1]
  def change
    add_column :link_clicks, :click_uuid, :string
  end
end
