# frozen_string_literal: true

# Concern to provide rollup-based data fetching for DashboardController.
# Replaces slow Detection queries with pre-computed rollup lookups.
#
module DashboardRollups
  extend ActiveSupport::Concern

  private

  # Get the rollup service instance for the current workspace/threshold
  def rollup_service
    @rollup_service ||= DashboardRollupService.new(
      workspace_id: @active_workspace.id,
      logit_margin_min: @logit_margin_threshold,
      group_member_ids: @group_member_ids,
      group_id: @selected_group&.id
    )
  end

  # Return [min_date, max_date] for current rollup subject (workspace/group), optionally scoped to metric.
  def rollup_date_bounds(metric_id: nil)
    rollup_service.date_bounds(metric_id: metric_id)
  end

  # Fetch daily counts from rollups (fast) or detections (fallback).
  # Returns: Hash of { Date => { pos: N, tot: N } }
  def fetch_daily_counts(start_date:, end_date:, metric_id: nil)
    raw = rollup_service.daily_counts(
      start_date: start_date,
      end_date: end_date,
      metric_id: metric_id
    )

    # Normalize to the expected format ({ date => { pos:, tot: } })
    result = Hash.new { |h, k| h[k] = { pos: 0, tot: 0 } }
    raw.each do |date, counts|
      result[date] = { pos: counts[:pos].to_i, tot: counts[:tot].to_i }
    end
    result
  end

  # Fetch aggregate totals for a date range
  def fetch_aggregate_counts(start_date:, end_date:, metric_id: nil)
    rollup_service.aggregate_counts(
      start_date: start_date,
      end_date: end_date,
      metric_id: metric_id
    )
  end

  # Fetch aggregate counts grouped by metric for a date range
  def fetch_metric_counts(start_date:, end_date:)
    rollup_service.counts_by_metric(start_date: start_date, end_date: end_date)
  end

  # Check if rollups are available (for logging/debugging)
  def rollups_available?
    rollup_service.rollups_available?
  end
end
