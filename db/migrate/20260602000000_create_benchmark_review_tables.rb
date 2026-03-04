class CreateBenchmarkReviewTables < ActiveRecord::Migration[7.1]
  def change
    create_table :benchmark_messages do |t|
      t.string :benchmark_set, null: false, default: "golden_rules_v1"
      t.string :external_message_id, null: false
      t.string :label_primary, null: false
      t.string :scenario_id
      t.text :message_text, null: false
      t.string :style_bucket
      t.string :length_bucket
      t.string :variant
      t.string :source_model
      t.string :source_provider
      t.string :source_prompt_version
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :benchmark_messages, :external_message_id, unique: true
    add_index :benchmark_messages, :benchmark_set
    add_index :benchmark_messages, :label_primary
    add_index :benchmark_messages, :scenario_id

    create_table :benchmark_labels do |t|
      t.references :benchmark_message, null: false, foreign_key: true
      t.string :label_name, null: false
      t.boolean :is_primary, null: false, default: false

      t.timestamps
    end

    add_index :benchmark_labels, [:benchmark_message_id, :label_name], unique: true
    add_index :benchmark_labels, :label_name

    create_table :benchmark_review_recommendations do |t|
      t.references :benchmark_message, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :label_name, null: false
      t.string :recommendation, null: false # agree | disagree | add
      t.text :notes
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :benchmark_review_recommendations,
              [:benchmark_message_id, :user_id, :label_name],
              unique: true,
              name: "idx_benchmark_review_recs_unique"
    add_index :benchmark_review_recommendations, :recommendation
  end
end
