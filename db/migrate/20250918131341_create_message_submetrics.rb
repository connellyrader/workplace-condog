class CreateMessageSubmetrics < ActiveRecord::Migration[7.1]
  def change
    create_table :message_submetrics do |t|
      t.references :message, null: false, foreign_key: true
      t.references :submetric, null: false, foreign_key: true
      t.references :model_test, null: false, foreign_key: true
      t.references :async_inference_result, null: false, foreign_key: true

      t.jsonb :full_output, default: {}

      t.timestamps
    end

    add_index :message_submetrics,
              [:message_id, :submetric_id, :model_test_id],
              unique: true,
              name: "index_message_submetrics_unique"

    add_column :submetrics, :description, :text
  end
end
