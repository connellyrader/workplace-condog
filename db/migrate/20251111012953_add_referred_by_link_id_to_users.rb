class AddReferredByLinkIdToUsers < ActiveRecord::Migration[7.1]
  def change
    add_reference :users, :referred_by_link, foreign_key: { to_table: :links }, null: true
  end
end
