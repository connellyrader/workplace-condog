class AddDetectionPolicyOptimizationIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = "idx_detections_policy_optimization"

  def up
    add_index :detections,
              [:message_id, :polarity, :logit_margin, :id],
              name: INDEX_NAME,
              where: "logit_margin IS NOT NULL",
              order: { logit_margin: :desc },
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :detections, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
