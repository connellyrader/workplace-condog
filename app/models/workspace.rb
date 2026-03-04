# app/models/workspace.rb
class Workspace < ApplicationRecord
  has_one_attached :icon do |attachable|
    attachable.variant :thumb,
                       resize_to_limit: [256, 256],
                       saver: { strip: true, quality: 80 }
  end

  has_many :integrations,        dependent: :destroy
  has_many :groups,              dependent: :destroy
  has_many :subscriptions,       dependent: :destroy
  has_many :insights,            dependent: :destroy
  has_many :workspace_invites,   dependent: :destroy

  # Through integrations you can reach everything Slack/Teams-y
  has_many :integration_users, through: :integrations
  has_many :channels,          through: :integrations
  has_many :messages,          through: :integrations

  # Single canonical owner
  belongs_to :owner, class_name: "User", optional: true

  # Membership via join table
  has_many :workspace_users, dependent: :destroy
  has_many :users, through: :workspace_users

  # Optional: convenience scope
  has_many :member_owners,
           -> { where(workspace_users: { is_owner: true }) },
           through: :workspace_users,
           source: :user

  before_validation :normalize_name

  validates :name, presence: true, length: { maximum: 60 }
  validates :name, format: {
    with: /\A[[:alnum:]][[:alnum:]\s\-\&\._']*\z/,
    message: "can only include letters, numbers, spaces, and - & . _ '"
  }

  scope :active,   -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  # Stripe customer anchor for this workspace
  # stripe_customer_id is stored here

  after_create :seed_default_notification_permissions

  def archived?
    archived_at.present?
  end

  # -------------------------------------------------------------------
  # BILLING: Billable seat count for Stripe subscription quantity
  #
  # Counts a UNION of:
  # - integration_users that are members of ANY group in this workspace
  # - integration_users associated to real workspace user accounts (via
  #   WorkspaceUser#integration_user_for_workspace, if available)
  #
  # Prevents double counting by deduping IU IDs.
  #
  # Also adds "missing_account_mappings" as a conservative safety bump for
  # workspace users that do not map to an integration_user record yet.
  # -------------------------------------------------------------------
  def billable_seat_count
    # Group-selected IU ids (ANY group in workspace)
    selected_iu_ids =
      GroupMember
        .joins(:group)
        .where(groups: { workspace_id: id })
        .distinct
        .pluck(:integration_user_id)

    ws_users = workspace_users.includes(:user).to_a

    account_iu_ids =
      ws_users.filter_map do |wu|
        wu.respond_to?(:integration_user_for_workspace) ? wu.integration_user_for_workspace&.id : nil
      end.compact

    missing_account_mappings =
      ws_users.count do |wu|
        wu.respond_to?(:integration_user_for_workspace) && wu.integration_user_for_workspace.nil?
      end

    union_count = (selected_iu_ids + account_iu_ids).uniq.size
    [union_count + missing_account_mappings, 1].max
  end

  private

  def normalize_name
    self.name = name.to_s.squish
  end

  def seed_default_notification_permissions
    defaults = {
      "owner"      => { enabled: true,  allowed_types: NotificationPreference::TYPE_KEYS },
      "admin"      => { enabled: true,  allowed_types: NotificationPreference::TYPE_KEYS },
      "viewer"     => { enabled: true,  allowed_types: %w[personal_insights my_group_insights] },
      "user"       => { enabled: true,  allowed_types: %w[personal_insights] },
      "no_account" => { enabled: false, allowed_types: %w[personal_insights] }
    }

    defaults.each do |account_type, attrs|
      WorkspaceNotificationPermission.find_or_create_by!(workspace: self, account_type: account_type) do |perm|
        perm.enabled       = attrs[:enabled]
        perm.allowed_types = attrs[:allowed_types]
      end
    end
  end
end
