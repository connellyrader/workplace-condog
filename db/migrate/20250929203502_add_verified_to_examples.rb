class AddVerifiedToExamples < ActiveRecord::Migration[7.1]
  def change
    add_column :examples, :length_type, :string
    add_column :examples, :style_type, :string
    add_column :examples, :generated_at, :datetime
    add_column :examples, :verified, :boolean

    add_index :examples, :verified
    add_index :examples, :length_type
    add_index :examples, :style_type
  end
end
