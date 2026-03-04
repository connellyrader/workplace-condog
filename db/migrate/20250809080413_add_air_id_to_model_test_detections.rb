class AddAirIdToModelTestDetections < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :admin, :boolean, default: false
    add_column :model_test_detections, :async_inference_result_id, :integer
    add_column :model_tests, :description, :string
  end
end
