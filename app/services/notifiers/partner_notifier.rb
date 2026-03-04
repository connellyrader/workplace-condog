module Notifiers
  class PartnerNotifier
    def self.new_customer(subscription:, customer:, amount_cents:, currency:)
      new(subscription: subscription, customer: customer, amount_cents: amount_cents, currency: currency).new_customer
    end

    def self.refund(charge:, reason: nil)
      new(charge: charge).refund(reason: reason)
    end

    def initialize(subscription: nil, customer: nil, amount_cents: nil, currency: nil, charge: nil)
      @subscription = subscription
      @customer     = customer || charge&.customer
      @amount_cents = amount_cents || charge&.amount
      @currency     = currency || charge&.respond_to?(:currency) && charge.currency
      @charge       = charge
    end

    def new_customer
      partner = partner_for_customer
      return false unless partner&.partner?

      WorkplaceMailer.partner_new_customer(
        partner: partner,
        customer: customer,
        amount_cents: amount_cents,
        currency: currency || "USD",
        subscription: subscription
      ).deliver_later
      true
    rescue => e
      Rails.logger.warn("[PartnerNotifier] new_customer failed: #{e.class}: #{e.message}")
      false
    end

    def refund(reason: nil)
      partner = partner_for_charge
      return false unless partner&.partner?

      WorkplaceMailer.partner_refund(
        partner: partner,
        customer: customer,
        amount_cents: amount_cents,
        currency: currency || "USD",
        reason: reason
      ).deliver_later
      true
    rescue => e
      Rails.logger.warn("[PartnerNotifier] refund failed: #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :subscription, :customer, :amount_cents, :currency, :charge

    def partner_for_customer
      return nil unless customer
      customer.referred_by_link&.user
    end

    def partner_for_charge
      if charge&.affiliate_id.present?
        User.find_by(id: charge.affiliate_id)
      else
        partner_for_customer
      end
    end
  end
end
