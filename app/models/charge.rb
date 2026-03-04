class Charge < ApplicationRecord
  belongs_to :subscription
  belongs_to :affiliate, class_name: "User"
  belongs_to :customer, class_name: "User", optional: true
  belongs_to :payout, optional: true

  validates :stripe_charge_id, presence: true, uniqueness: true
  validates :amount, presence: true

  after_create :notify_partner_on_refund

  scope :unpaid, -> { where(payout_id: nil) }

  def net_amount
    amount - stripe_fee
  end

  def paid?
    payout_id.present?
  end

  private

  def notify_partner_on_refund
    return unless amount.to_i.negative?

    Notifiers::PartnerNotifier.refund(charge: self)
  rescue => e
    Rails.logger.warn("[Charge] refund notification failed charge_id=#{id}: #{e.class}: #{e.message}")
    nil
  end
end
