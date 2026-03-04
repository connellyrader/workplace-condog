class BenchmarkReviewRecommendation < ApplicationRecord
  RECOMMENDATIONS = %w[agree disagree add].freeze

  belongs_to :benchmark_message
  belongs_to :user

  validates :label_name, presence: true
  validates :recommendation, inclusion: { in: RECOMMENDATIONS }
  validates :label_name, uniqueness: { scope: [:benchmark_message_id, :user_id] }
end
