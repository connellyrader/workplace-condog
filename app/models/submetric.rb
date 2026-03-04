class Submetric < ApplicationRecord
  belongs_to :metric
  has_many :model_test_detections, dependent: :destroy
  has_many :signal_categories
end
