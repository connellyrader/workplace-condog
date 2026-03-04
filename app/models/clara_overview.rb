class ClaraOverview < ApplicationRecord
  encrypts :content

  belongs_to :workspace
  belongs_to :metric

  enum status: {
    pending:    "pending",
    generating: "generating",
    ready:      "ready",
    failed:     "failed"
  }, _suffix: true

  scope :for_workspace_metric, ->(workspace_id, metric_id) {
    where(workspace_id: workspace_id, metric_id: metric_id)
  }

  scope :for_range, ->(start_date, end_date) {
    where(range_start: start_date, range_end: end_date)
  }

  scope :for_group_scope, ->(group_scope) {
    where(group_scope: group_scope)
  }

  validates :status, inclusion: { in: statuses.keys }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def fresh?
    ready_status? && !expired?
  end
end
