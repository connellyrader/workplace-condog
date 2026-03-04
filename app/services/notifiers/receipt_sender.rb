module Notifiers
  class ReceiptSender
    RECEIPT_METADATA_KEY = "workplace_receipt_sent"

    def self.send_for_invoice(workspace:, invoice:)
      new(workspace, invoice).send!
    end

    def initialize(workspace, invoice)
      @workspace = workspace
      @invoice = invoice
    end

    def send!
      return false unless workspace && invoice
      return false unless paid_invoice?
      return false if receipt_already_sent?

      WorkplaceMailer.receipt(workspace: workspace, invoice: invoice).deliver_later
      mark_receipt_sent!
      true
    rescue => e
      Rails.logger.warn("[ReceiptSender] failed workspace_id=#{workspace&.id} invoice_id=#{invoice_id}: #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :workspace, :invoice

    def invoice_id
      invoice.respond_to?(:[]) ? invoice["id"] : nil
    end

    def paid_invoice?
      invoice.respond_to?(:[]) && invoice["status"].to_s == "paid"
    end

    def receipt_already_sent?
      meta = invoice.respond_to?(:[]) ? invoice["metadata"] : nil
      meta.respond_to?(:[]) && meta[RECEIPT_METADATA_KEY].to_s == "true"
    end

    def mark_receipt_sent!
      return unless invoice_id
      return unless defined?(Stripe)

      Stripe::Invoice.update(invoice_id, metadata: { RECEIPT_METADATA_KEY => "true" })
    rescue => e
      Rails.logger.warn("[ReceiptSender] mark_receipt_sent_failed invoice_id=#{invoice_id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
