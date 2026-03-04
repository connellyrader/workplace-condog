# app/models/workspace_user.rb
class WorkspaceUser < ApplicationRecord
  belongs_to :workspace
  belongs_to :user

  scope :owners, -> { where(is_owner: true) }

  # Keep Stripe seats in sync when membership changes (invites accepted / members removed).
  # NOTE: group membership changes are handled elsewhere because your code uses delete_all.
  after_commit :queue_stripe_qty_sync, on: [:create, :destroy]

  validate :owner_flag_and_role_consistent
  before_validation :normalize_owner_role

  # IntegrationUser for this workspace (if any)
  def integration_user_for_workspace
    @integration_user_for_workspace ||= begin
      # Assuming user.integration_users is preloaded in your includes
      user.integration_users.detect { |iu| iu.integration&.workspace_id == workspace_id }
    end
  end

  def provider_kind
    iu = integration_user_for_workspace
    iu&.integration&.kind.to_s.titleize.presence || "Unknown"
  end

  def avatar_url_for_workspace
    integration_user_for_workspace&.avatar_url
  end

  # ---- Data status for account holders ----
  #
  # Final states you want:
  # - "No data"        → user is not in any groups in this workspace
  # - "Data synced"    → in groups AND has a personal token
  # - "Partial data"   → in groups AND no personal token (data only via others' tokens)
  #
  def data_status_key
    iu = integration_user_for_workspace

    # "In a group" is the gate for whether we use their data for scores
    in_group =
      if iu
        iu.groups.where(workspace_id: workspace_id).exists?
      else
        false
      end

    # If not in any group, we aren't using their data at all
    return :no_data unless in_group

    # In one or more groups:
    if iu&.slack_history_token.present?
      :data_synced
    else
      :partial_data
    end
  end

  def data_status_label
    case data_status_key
    when :data_synced
      "Data synced"
    when :partial_data
      "Partial data"
    when :no_data
      "No data"
    else
      "Unknown"
    end
  end

  def owner?
    is_owner?
  end

  def admin?
    role.to_s == "admin"
  end

  def viewer?
    role.to_s == "viewer"
  end

  def basic_user?
    role.present? && !owner? && !admin? && !viewer?
  end

  def account_type
    return "owner" if owner?
    return "admin" if admin?
    return "viewer" if viewer?
    "user"
  end

  private

  def queue_stripe_qty_sync
    return unless workspace_id
    SyncStripeSubscriptionQtyJob.perform_later(workspace_id)
  rescue => e
    Rails.logger.warn("[WorkspaceUser] queue_stripe_qty_sync failed: #{e.class}: #{e.message}")
  end

  # Ensure is_owner and role never conflict (prevents `is_owner: true, role: "user"` situations)
  def normalize_owner_role
    self.role = "owner" if is_owner?
  end

  def owner_flag_and_role_consistent
    if is_owner? && role.to_s != "owner"
      errors.add(:role, "must be owner when is_owner is true")
    end

    if role.to_s == "owner" && !is_owner?
      errors.add(:is_owner, "must be true when role is owner")
    end
  end

  # You can keep this helper around in case you want per-user "fully synced" logic later,
  # but it is no longer used by data_status_key.
  def data_fully_synced_for?(integration_user)
    cutoff_time = 12.hours.ago

    msgs = Message
      .joins(:integration)
      .where(
        integration_user_id: integration_user.id,
        integrations: { workspace_id: workspace_id }
      )
      .where("messages.posted_at <= ?", cutoff_time)

    # If there are no messages older than the cutoff, treat them as synced —
    # there's nothing "stale" left to process for this person.
    return true if msgs.empty?

    # Fully synced = no unprocessed messages in that older window
    msgs.where(processed: false).none?
  rescue
    false
  end
end
