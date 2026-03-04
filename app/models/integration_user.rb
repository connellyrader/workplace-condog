class IntegrationUser < ApplicationRecord
  encrypts :slack_history_token, :slack_bot_token, :slack_refresh_token
  encrypts :ms_access_token, :ms_refresh_token

  belongs_to :integration
  belongs_to :user, optional: true

  has_many :messages,            dependent: :destroy
  has_many :team_memberships,    dependent: :destroy
  has_many :teams,               through: :team_memberships
  has_many :channel_memberships, dependent: :destroy
  has_many :channels,            through: :channel_memberships
  has_many :channel_identities,  dependent: :nullify
  has_many :group_members,       dependent: :destroy
  has_many :groups,              through: :group_members

  validates :slack_user_id,
            uniqueness: { scope: :integration_id },
            allow_nil: true

  # ------------------------------------------------------------------
  # Humans: exclude bots robustly.
  #
  # - Primary: is_bot must be false/nil
  # - Slack-only hard excludes:
  #     slack_user_id LIKE 'bot:%'
  #     slack_user_id IN ('USLACKBOT', 'system')
  #
  # IMPORTANT: do NOT apply slack_user_id pattern checks to Teams,
  # because Teams also stores ms_user_id in slack_user_id.
  # ------------------------------------------------------------------
  scope :humans, -> {
    where(is_bot: [false, nil])
      .where.not(
        id: IntegrationUser
              .joins(:integration)
              .where(integrations: { kind: "slack" })
              .where(
                "integration_users.slack_user_id LIKE 'bot:%' OR integration_users.slack_user_id IN ('USLACKBOT','system')"
              )
              .select(:id)
      )
  }

  scope :without_account, -> { where(user_id: nil) }

  # Workspace-aware "no account" for a specific workspace:
  # Includes:
  #  - integration_users with NULL user_id
  #  - integration_users whose user_id is NOT a workspace_user for this workspace
  scope :without_workspace_account_for, ->(workspace) do
    wid = workspace.is_a?(Workspace) ? workspace.id : workspace.to_i

    where(<<~SQL, wid: wid)
      integration_users.user_id IS NULL
      OR NOT EXISTS (
        SELECT 1
        FROM workspace_users
        WHERE workspace_users.workspace_id = :wid
          AND workspace_users.user_id = integration_users.user_id
      )
    SQL
  end

  def connected?
    user.present?
  end

  delegate :workspace, to: :integration

  def data_status_key_for_workspace(target_workspace = workspace)
    msgs = Message
      .joins(:integration)
      .where(
        integration_user_id: id,
        integrations: { workspace_id: target_workspace.id }
      )

    return :no_data if msgs.empty?
    :partial_data
  rescue
    :no_data
  end

  def data_status_label_for_workspace(target_workspace = workspace)
    case data_status_key_for_workspace(target_workspace)
    when :partial_data then "Partial data"
    when :no_data      then "No data"
    else                    "Unknown"
    end
  end
end
