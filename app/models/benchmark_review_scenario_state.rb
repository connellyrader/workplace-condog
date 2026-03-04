class BenchmarkReviewScenarioState < ApplicationRecord
  belongs_to :user

  validates :benchmark_set, :label_primary, :scenario_id, presence: true
end
