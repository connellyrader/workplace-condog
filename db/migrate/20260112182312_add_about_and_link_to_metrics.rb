class AddAboutAndLinkToMetrics < ActiveRecord::Migration[7.1]
  def change
    add_column :metrics, :about, :text
    add_column :metrics, :link,  :string
  end
end
