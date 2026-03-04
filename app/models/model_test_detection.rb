class ModelTestDetection < ApplicationRecord
  belongs_to :model_test
  belongs_to :message
  belongs_to :signal_category
  belongs_to :signal_subcategory
  belongs_to :async_inference_result, optional: true

  validates :score, numericality: true
end