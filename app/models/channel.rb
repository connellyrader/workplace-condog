class Channel < ApplicationRecord
  belongs_to :integration
  belongs_to :team, optional: true #if connected to MS Teams and not Slack

  has_many :messages,            dependent: :destroy
  has_many :channel_memberships, dependent: :destroy
  has_many :integration_users,   through: :channel_memberships
  has_many :channel_identities,  dependent: :destroy

  # The Slack API channel ID must be present and unique per integration
  validates :external_channel_id,
            presence: true,
            uniqueness: { scope: :integration_id }

  # allow is_private to be nil for DMs
  validates :is_private, inclusion: { in: [true, false] }, allow_nil: true

  enum kind: {
    public_channel:  "public_channel",
    private_channel: "private_channel",
    im:              "im",
    mpim:            "mpim"
  }
  scope :needing_backfill, -> { where(backfill_complete: false, history_unreachable: false).where.not(name: nil) }
  scope :needing_audit,    -> { where.not(forward_newest_ts: nil) }

  def mark_history_ok! = update!(
    last_history_status:  "ok",
    last_history_error:   nil,
    history_unreachable:  false
  )

  def mark_history_error!(msg, unreachable: false) = update!(
    last_history_status:  unreachable ? "unreachable" : "error",
    last_history_error:   msg,
    history_unreachable:  unreachable
  )

  # Returns float seconds (UTC) for anchor/cursor; nil-safe
  def backfill_anchor_ts
    backfill_anchor_latest_ts&.to_f
  end

  def backfill_cursor_ts
    backfill_next_oldest_ts&.to_f
  end

  # Slack has created_unix; Teams channels likely won't. If nil, treat as 0.
  def created_boundary_ts
    (created_unix.presence || 0).to_f
  end

  # Derived: ready for last N days (default 30), accounting for newer channels
  def backfill_ready_for_days?(days = 30)
    a = backfill_anchor_ts
    c = backfill_cursor_ts
    return false if a.nil? || c.nil?

    cutoff = [a - days.days.to_i, created_boundary_ts].max
    c <= cutoff
  end

  # Derived: fully complete backfill to channel creation boundary
  def backfill_fully_complete?
    return true if backfill_complete?
    a = backfill_anchor_ts
    c = backfill_cursor_ts
    return false if a.nil? || c.nil?

    c <= created_boundary_ts
  end

  def slack_external_id_for(integration_user: nil)
    identity = ChannelIdentity.preferred_for(channel: self, integration_user: integration_user, provider: "slack")
    identity&.external_channel_id || external_channel_id
  end
end
