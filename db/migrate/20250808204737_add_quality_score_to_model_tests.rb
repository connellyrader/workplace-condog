class AddQualityScoreToModelTests < ActiveRecord::Migration[7.1]
  def change
    add_column :model_tests, :prev_message_count, :integer, default: 5
    add_column :model_tests, :prev_detection_count, :integer, default: 5
    add_column :model_tests, :scoring_instructions, :string
    add_column :model_tests, :output_instructions, :string
    add_column :model_tests, :ai_quality_reviewed, :boolean, default: false
    add_column :model_tests, :human_quality_reviewed, :boolean, default: false

    add_column :model_test_detections, :indicator_type, :string
    add_column :model_test_detections, :ai_quality_score, :integer
    add_column :model_test_detections, :human_quality_score, :integer

    add_column :async_inference_results, :inference_arn, :string
    add_column :async_inference_results, :input_tokens, :integer
    add_column :async_inference_results, :output_tokens, :integer
    add_column :async_inference_results, :duration, :float
    add_column :async_inference_results, :completed_at, :datetime
    add_column :async_inference_results, :inference_type, :string
    add_column :async_inference_results, :model_test_detection_id, :integer

    reversible do |dir|
      dir.up   { change_column :model_tests, :duration, :float, using: 'duration::float' }
      dir.down { change_column :model_tests, :duration, :integer, using: 'duration::integer' }
    end

    create_table :aws_instances do |t|
      t.string :instance_type
      t.float  :hourly_price
      t.timestamps
    end

    add_column :models, :aws_instance_id, :integer
  end
end
