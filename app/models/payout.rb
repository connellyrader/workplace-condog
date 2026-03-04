class Payout < ApplicationRecord
  belongs_to :user
  belongs_to :payout_method, optional: true

  has_many :charges

  validates :amount, :start_date, :end_date, presence: true

  enum status: {
    pending:  "pending",
    paid:     "paid",
    failed:   "failed"
  }

  def paid?
    paid_at.present?
  end
end
