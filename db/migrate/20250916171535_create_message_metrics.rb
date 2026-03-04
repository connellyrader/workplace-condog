class CreateMessageMetrics < ActiveRecord::Migration[7.1]
  def change
    create_table :message_metrics do |t|
      t.references :message, null: false, foreign_key: true
      t.references :metric, null: false, foreign_key: true
      t.references :model_test, foreign_key: true
      t.references :async_inference_result, foreign_key: true
      t.jsonb :full_output

      t.timestamps
    end
    add_index :message_metrics, [:message_id, :metric_id]
  end
end
