class BenchmarkLabel < ApplicationRecord
  belongs_to :benchmark_message, optional: true

  validates :label_name, presence: true
end
