# frozen_string_literal: true

# Scheduled job to maintain rollup data freshness.
# Run every 15-30 minutes to catch any missed real-time updates.
#
# Schedule with Sidekiq-cron, Clockwork, or similar:
#   RollupMaintenanceJob.perform_later
#
class RollupMaintenanceJob < ApplicationJob
  queue_as :low

  # Only rebuild recent days (real-time updates should handle most)
  RECENT_DAYS = 3

  def perform(workspace_id: nil)
    logit_margin_min = ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f

    workspaces = if workspace_id
      Workspace.where(id: workspace_id)
    else
      Workspace.joins(:integrations).distinct
    end

    workspaces.find_each do |workspace|
      rebuild_recent_rollups!(workspace, logit_margin_min)
    end
  end

  private

  def rebuild_recent_rollups!(workspace, logit_margin_min)
    end_date = Date.current
    start_date = end_date - RECENT_DAYS.days

    builder = Insights::RollupBuilder.new(
      workspace: workspace,
      logit_margin_min: logit_margin_min,
      start_date: start_date,
      end_date: end_date,
      logger: Rails.logger
    )

    builder.run!
    Rails.logger.info("[RollupMaintenanceJob] Refreshed rollups for workspace #{workspace.id} (#{start_date} to #{end_date})")
  rescue => e
    Rails.logger.error("[RollupMaintenanceJob] Failed for workspace #{workspace.id}: #{e.class} #{e.message}")
  end
end

