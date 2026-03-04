class AsyncInferenceResult < ApplicationRecord
  belongs_to :model_test
  belongs_to :model_test_detection, optional: true
  belongs_to :message, optional: true
end
