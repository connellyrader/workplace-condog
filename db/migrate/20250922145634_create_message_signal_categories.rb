class CreateMessageSignalCategories < ActiveRecord::Migration[7.1]
  def change
    create_table :message_signal_categories do |t|
      t.references :message, null: false, foreign_key: true
      t.references :signal_category, null: false, foreign_key: true
      t.references :model_test, null: false, foreign_key: true
      t.references :async_inference_result, null: false, foreign_key: true
      t.jsonb :full_output, default: {}

      t.timestamps
    end

    add_index :message_signal_categories,
              [:message_id, :signal_category_id, :model_test_id],
              unique: true,
              name: "index_msg_sigcat_unique"

    add_column :signal_categories, :description, :text
  end
end
