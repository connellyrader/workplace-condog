class WorkspaceNotificationPermission < ApplicationRecord
  ACCOUNT_TYPES = %w[owner admin viewer user no_account].freeze

  belongs_to :workspace

  validates :account_type, presence: true, inclusion: { in: ACCOUNT_TYPES }

  def enabled?
    self[:enabled] != false
  end

  def allowed_types
    raw = self[:allowed_types]
    raw = NotificationPreference::TYPE_KEYS if raw.nil?
    Array(raw).map(&:to_s) & NotificationPreference::TYPE_KEYS
  end

  def allowed_types=(values)
    self[:allowed_types] = Array(values).map(&:to_s).uniq & NotificationPreference::TYPE_KEYS
  end

  def self.for(workspace, account_type)
    find_by(workspace: workspace, account_type: account_type) ||
      new(workspace: workspace, account_type: account_type,
          enabled: true, allowed_types: NotificationPreference::TYPE_KEYS)
  end
end
