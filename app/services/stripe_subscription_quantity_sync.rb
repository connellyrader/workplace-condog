# app/services/stripe_subscription_quantity_sync.rb
class StripeSubscriptionQuantitySync
  # Entry point
  def self.call(workspace:)
    new(workspace).call
  end

  def initialize(workspace)
    @workspace = workspace
  end

  def call
    stripe_sub_id = latest_stripe_subscription_id
    return if stripe_sub_id.blank?

    desired_qty = @workspace.billable_seat_count

    stripe_sub = Stripe::Subscription.retrieve(
      { id: stripe_sub_id, expand: ["items.data"] }
    )

    status = stripe_sub["status"].to_s
    return unless syncable_status?(status)

    item = Array(stripe_sub.items&.data).first
    return unless item

    current_qty = item.quantity.to_i
    return if current_qty == desired_qty

    # Update the subscription item quantity without proration
    Stripe::Subscription.update(
      stripe_sub_id,
      {
        proration_behavior: "none",
        items: [{ id: item.id, quantity: desired_qty }]
      }
    )

    Rails.logger.info("[StripeQtySync] ws=#{@workspace.id} sub=#{stripe_sub_id} qty #{current_qty} -> #{desired_qty}")
    true
  rescue Stripe::StripeError => e
    Rails.logger.warn("[StripeQtySync] ws=#{@workspace.id} failed: #{e.class}: #{e.message}")
    false
  rescue => e
    Rails.logger.warn("[StripeQtySync] ws=#{@workspace.id} failed: #{e.class}: #{e.message}")
    false
  end

  private

  def syncable_status?(status)
    # Keep broad, but safe. You can tighten if you want only active/trialing.
    %w[active trialing past_due unpaid incomplete].include?(status)
  end

  def latest_stripe_subscription_id
    sub_rec =
      @workspace.subscriptions
                .order(created_at: :desc)
                .find_by(status: %w[active trialing past_due unpaid incomplete canceled]) ||
      @workspace.subscriptions.order(created_at: :desc).first

    sub_rec&.stripe_subscription_id.to_s.presence
  end
end
