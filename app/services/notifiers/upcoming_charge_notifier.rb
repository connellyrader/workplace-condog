module Notifiers
  class UpcomingChargeNotifier
    def self.call(workspace:, amount_cents:, currency:, billing_date:, seats: nil)
      new(workspace, amount_cents, currency, billing_date, seats).call
    end

    def initialize(workspace, amount_cents, currency, billing_date, seats)
      @workspace = workspace
      @amount_cents = amount_cents
      @currency = currency
      @billing_date = billing_date
      @seats = seats
    end

    def call
      return false unless workspace&.owner
      return false unless amount_cents.to_i.positive?
      return false unless billing_date

      WorkplaceMailer.receipt_upcoming(
        workspace: workspace,
        billing_date: billing_date,
        amount_cents: amount_cents,
        currency: currency || "USD",
        description: description,
        receipt_id: receipt_id
      ).deliver_later
      true
    rescue => e
      Rails.logger.warn("[UpcomingChargeNotifier] failed workspace_id=#{workspace&.id}: #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :workspace, :amount_cents, :currency, :billing_date, :seats

    def description
      seats.present? ? "#{ApplicationMailer::PRODUCT_NAME} subscription (#{seats} seats)" : "#{ApplicationMailer::PRODUCT_NAME} subscription"
    end

    def receipt_id
      "Upcoming charge #{billing_date}"
    end
  end
end
