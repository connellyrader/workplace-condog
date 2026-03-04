class Insight < ApplicationRecord
  belongs_to :workspace
  belongs_to :subject, polymorphic: true
  belongs_to :metric, optional: true
  belongs_to :trigger_template,
             class_name: "InsightTriggerTemplate",
             optional: true

  has_many :driver_items,
           class_name: "InsightDriverItem",
           dependent: :destroy,
           inverse_of: :insight
  has_many :deliveries,
           class_name: "InsightDelivery",
           dependent: :destroy,
           inverse_of: :insight

  KINDS = %w[risk_spike improvement recovery hotspot bright_spot exec_summary topic_shift].freeze
  POLARITIES = %w[negative positive mixed].freeze

  enum state: {
    pending:    "pending",
    sent:       "sent",
    suppressed: "suppressed"
  }, _suffix: true

  validates :workspace, :subject, :kind, :polarity, :window_start_at, :window_end_at, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :polarity, inclusion: { in: POLARITIES }
  validates :state, inclusion: { in: states.keys }
  validates :severity,
            presence: true,
            numericality: { greater_than_or_equal_to: 0 }
end
