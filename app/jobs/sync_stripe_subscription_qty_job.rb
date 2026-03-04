# app/jobs/sync_stripe_subscription_qty_job.rb
class SyncStripeSubscriptionQtyJob < ApplicationJob
  queue_as :default

  # Simple debounce so multiple seat-changing actions don't hammer Stripe.
  # (Example: editing Everyone group removes + adds many rows.)
  DEBOUNCE_TTL = 10.seconds

  # Usage:
  #   SyncStripeSubscriptionQtyJob.perform_later(workspace.id)
  #
  # Optional:
  #   SyncStripeSubscriptionQtyJob.perform_later(workspace.id, force: true)
  #
  def perform(workspace_id, force: false)
    ws = Workspace.find_by(id: workspace_id)
    return unless ws

    unless force
      return if recently_synced?(ws.id)
      mark_recently_synced!(ws.id)
    end

    StripeSubscriptionQuantitySync.call(workspace: ws)
  end

  private

  def debounce_key(workspace_id)
    "stripe:qty_sync:ws:#{workspace_id}"
  end

  def recently_synced?(workspace_id)
    Rails.cache.read(debounce_key(workspace_id)).present?
  rescue
    false
  end

  def mark_recently_synced!(workspace_id)
    key = debounce_key(workspace_id)

    # Prefer atomic write if supported by cache store
    Rails.cache.write(key, true, expires_in: DEBOUNCE_TTL, unless_exist: true)
  rescue
    # Fallback for cache stores that don't support unless_exist
    Rails.cache.write(key, true, expires_in: DEBOUNCE_TTL)
  end
end
