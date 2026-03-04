class PayoutMethod < ApplicationRecord
  belongs_to :user

  enum method: {
    paypal:        "paypal",
    bank_transfer: "bank_transfer",
    trolley:       "trolley"
  }

  validates :method, presence: true
  validates :details, presence: true

  before_save :ensure_single_default

  def default?
    is_default
  end

  private

  def ensure_single_default
    return unless is_default?

    user.payout_methods.where.not(id: id).update_all(is_default: false)
  end
end
