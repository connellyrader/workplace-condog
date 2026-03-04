class CreateModelTests < ActiveRecord::Migration[7.1]
  def change
    create_table :model_tests do |t|
      t.string :name
      t.string :test_type, null: false
      t.text :context
      t.references :workspace
      t.references :model
      t.references :signal_category
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :estimated_cost
      t.integer :duration
      t.timestamps
    end

    create_table :metrics do |t|
      t.references :framework
      t.string :name 
      t.timestamps
    end

    create_table :submetrics do |t|
      t.references :metric, foreign_key: true, null: false
      t.string :name
      t.timestamps
    end

    create_table :signal_categories do |t|
      t.references :submetric, foreign_key: true, null: false
      t.string :name
      t.timestamps
    end

    create_table :signal_subcategories do |t|
      t.references :signal_category, foreign_key: true, null: false
      t.string :name
      t.timestamps
    end

    create_table :signal_indicators do |t|
      t.references :signal_subcategory, foreign_key: true, null: false
      t.string :text
      t.string :indicator_type
      t.timestamps
    end

    create_table :async_inference_results do |t|
      t.references :model_test, foreign_key: true, null: false
      t.references :message
      t.string :response_location
      t.string :status
      t.timestamps
    end

    create_table :model_test_detections do |t|
      t.references :model_test, foreign_key: true, null: false
      t.references :message, foreign_key: true, null: false
      t.references :signal_category, foreign_key: true, null: false
      t.string :description
      t.decimal :score, precision: 5, scale: 2
      t.text :provided_context
      t.text :full_output
      t.timestamps
    end
  end
end
