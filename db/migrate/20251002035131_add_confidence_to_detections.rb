class AddConfidenceToDetections < ActiveRecord::Migration[7.1]
  def change
    # confidence: probability in [0,1] with micro precision
    add_column :model_test_detections, :confidence, :decimal, precision: 8, scale: 6
    # logit: can be negative/positive; give a bit more integer room
    add_column :model_test_detections, :logit, :decimal, precision: 12, scale: 6

    add_index :model_test_detections, :confidence
    add_index :model_test_detections, :logit
  end
end
