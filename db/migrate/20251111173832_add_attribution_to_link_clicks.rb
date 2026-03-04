class AddAttributionToLinkClicks < ActiveRecord::Migration[7.1]
  def change
    add_column :link_clicks, :referer_domain, :string
    add_column :link_clicks, :device_type,    :string   # 'desktop'|'mobile'|'tablet'|'bot'
    add_column :link_clicks, :os,             :string
    add_column :link_clicks, :browser,        :string
    add_column :link_clicks, :country,        :string
    add_column :link_clicks, :region,         :string
    add_column :link_clicks, :city,           :string
    add_column :link_clicks, :is_mobile,      :boolean, default: false, null: false
    add_column :link_clicks, :is_bot,         :boolean, default: false, null: false

    add_index  :link_clicks, :referer_domain
    add_index  :link_clicks, :device_type
    add_index  :link_clicks, :country
  end
end
