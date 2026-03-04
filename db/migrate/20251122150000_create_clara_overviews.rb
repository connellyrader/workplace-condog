class CreateClaraOverviews < ActiveRecord::Migration[7.1]
  def change
    create_table :clara_overviews do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :metric,    null: false, foreign_key: true
      t.text     :content
      t.string   :status,       null: false, default: "pending"
      t.datetime :generated_at
      t.datetime :expires_at
      t.text     :error_message
      t.string   :openai_model
      t.string   :request_id

      t.timestamps
    end

    add_index :clara_overviews, [:workspace_id, :metric_id, :created_at], name: "index_clara_overviews_on_ws_metric_created_at"
    add_index :clara_overviews, :status
    add_index :clara_overviews, :expires_at
  end
end
