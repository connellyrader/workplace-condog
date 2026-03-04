# app/models/group_member.rb
class GroupMember < ApplicationRecord
  belongs_to :group
  belongs_to :integration_user

  # If you ever switch your controller code from delete_all -> destroy_all,
  # these callbacks will automatically keep Stripe seat counts in sync.
  # (Right now, delete_all bypasses callbacks, so you should still enqueue
  # SyncStripeSubscriptionQtyJob explicitly in the controller after bulk changes.)
  after_commit :queue_stripe_qty_sync, on: [:create, :destroy]

  private

  def queue_stripe_qty_sync
    ws_id = group&.workspace_id
    return unless ws_id

    SyncStripeSubscriptionQtyJob.perform_later(ws_id)
  rescue => e
    Rails.logger.warn("[GroupMember] queue_stripe_qty_sync failed: #{e.class}: #{e.message}")
  end
end
