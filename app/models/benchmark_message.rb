class BenchmarkMessage < ApplicationRecord
  has_many :benchmark_labels, dependent: :destroy
  has_many :benchmark_review_recommendations, dependent: :destroy

  validates :external_message_id, presence: true, uniqueness: true
  validates :label_primary, presence: true
  validates :message_text, presence: true

  scope :for_set, ->(set_name) { where(benchmark_set: set_name) if set_name.present? }
end
