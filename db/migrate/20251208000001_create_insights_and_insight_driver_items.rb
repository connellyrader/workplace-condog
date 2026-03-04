class CreateInsightsAndInsightDriverItems < ActiveRecord::Migration[7.1]
  def change
    create_table :insights do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.references :metric, foreign_key: true

      t.string :kind, null: false
      t.string :polarity, null: false
      t.float :severity, null: false

      t.datetime :window_start_at, null: false
      t.datetime :window_end_at, null: false
      t.datetime :baseline_start_at
      t.datetime :baseline_end_at

      t.string :summary_title
      t.text :summary_body

      t.jsonb :data_payload, null: false, default: {}

      t.string :state, null: false, default: "pending"
      t.datetime :delivered_at
      t.datetime :next_eligible_at

      t.timestamps
    end

    add_index :insights, [:workspace_id, :subject_type, :subject_id]
    add_index :insights, [:workspace_id, :metric_id]
    add_index :insights, :state
    add_index :insights, [:workspace_id, :subject_type, :subject_id, :created_at],
              name: "index_insights_on_subject_and_created_at",
              order: { created_at: :desc }

    create_table :insight_driver_items do |t|
      t.references :insight, null: false, foreign_key: true
      t.string :driver_type, null: false
      t.bigint :driver_id, null: false
      t.float :weight

      t.timestamps
    end

    add_index :insight_driver_items, [:driver_type, :driver_id]
  end
end
