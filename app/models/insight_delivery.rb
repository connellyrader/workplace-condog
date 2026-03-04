class InsightDelivery < ApplicationRecord
  CHANNELS = %w[email slack teams].freeze
  STATUSES = %w[pending sent failed].freeze

  belongs_to :insight
  belongs_to :user, optional: true

  validates :channel, presence: true, inclusion: { in: CHANNELS }
  validates :status, presence: true, inclusion: { in: STATUSES }
end
