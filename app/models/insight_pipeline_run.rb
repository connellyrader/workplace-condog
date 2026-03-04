class InsightPipelineRun < ApplicationRecord
  belongs_to :workspace

  validates :workspace, :snapshot_at, :mode, :status, :logit_margin_min, presence: true
  validates :mode, inclusion: { in: %w[dry_run persist] }
  validates :status, inclusion: { in: %w[running ok error] }
end
