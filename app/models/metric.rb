class Metric < ApplicationRecord
  has_many :submetrics, dependent: :destroy
  has_many :insights, dependent: :nullify

  validates :name, presence: true
end
