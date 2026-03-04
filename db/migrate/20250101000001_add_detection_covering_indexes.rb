class AddDetectionCoveringIndexes < ActiveRecord::Migration[7.1]
  def change
    add_index :detections, [:metric_id, :logit_ratio],
              name: "index_detections_on_metric_logit_ratio_partial",
              where: "logit_ratio >= 1.0"

    add_index :detections, [:submetric_id, :logit_ratio],
              name: "index_detections_on_submetric_logit_ratio_partial",
              where: "logit_ratio >= 1.0"

    add_index :detections, [:signal_category_id, :logit_ratio],
              name: "index_detections_on_signal_category_logit_ratio_partial",
              where: "logit_ratio >= 1.0"

    add_index :messages, [:integration_user_id, :posted_at],
              name: "index_messages_on_integration_user_id_and_posted_at"
  end
end
