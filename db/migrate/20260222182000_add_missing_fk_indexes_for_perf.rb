class AddMissingFkIndexesForPerf < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    unless index_exists?(:detections, :async_inference_result_id, name: "index_detections_on_async_inference_result_id")
      add_index :detections, :async_inference_result_id,
        algorithm: :concurrently,
        name: "index_detections_on_async_inference_result_id"
    end

    unless index_exists?(:detections, :model_test_id, name: "index_detections_on_model_test_id")
      add_index :detections, :model_test_id,
        algorithm: :concurrently,
        name: "index_detections_on_model_test_id"
    end

    unless index_exists?(:workspace_insight_template_overrides, :trigger_template_id, name: "index_ws_insight_template_overrides_on_trigger_template_id")
      add_index :workspace_insight_template_overrides, :trigger_template_id,
        algorithm: :concurrently,
        name: "index_ws_insight_template_overrides_on_trigger_template_id"
    end
  end

  def down
    remove_index :detections, name: "index_detections_on_async_inference_result_id", algorithm: :concurrently if index_exists?(:detections, name: "index_detections_on_async_inference_result_id")
    remove_index :detections, name: "index_detections_on_model_test_id", algorithm: :concurrently if index_exists?(:detections, name: "index_detections_on_model_test_id")
    remove_index :workspace_insight_template_overrides, name: "index_ws_insight_template_overrides_on_trigger_template_id", algorithm: :concurrently if index_exists?(:workspace_insight_template_overrides, name: "index_ws_insight_template_overrides_on_trigger_template_id")
  end
end
