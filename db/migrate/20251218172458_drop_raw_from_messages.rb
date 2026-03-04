# db/migrate/20251218190000_drop_raw_from_messages.rb
class DropRawFromMessages < ActiveRecord::Migration[7.1]
  def up
    remove_column :messages, :raw, :jsonb if column_exists?(:messages, :raw)
  end

  def down
    add_column :messages, :raw, :jsonb, default: {}, null: false unless column_exists?(:messages, :raw)
  end
end
