class AllowNullTextOnMessages < ActiveRecord::Migration[7.1]
  def change
    change_column_null :messages, :text, true
  end
end
