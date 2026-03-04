# frozen_string_literal: true

# Service to fetch dashboard data from pre-computed rollups instead of raw detections.
# Falls back to raw detection queries if rollups are not available.
#
# Usage:
#   service = DashboardRollupService.new(workspace_id: 1, logit_margin_min: 0.0)
#   daily_counts = service.daily_counts(start_date: 30.days.ago, end_date: Date.current)
#   # => { Date => { pos: N, neg: N, tot: N }, ... }
#
class DashboardRollupService
  MIN_ROLLUP_ROWS = 10 # Minimum rollups to consider them "available"

  def initialize(workspace_id:, logit_margin_min: nil, group_member_ids: nil, group_id: nil)
    @workspace_id = workspace_id
    @logit_margin_min = (logit_margin_min.presence || ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")).to_f
    @group_member_ids = group_member_ids
    @group_id = group_id
  end

  # Check if rollups are populated for this workspace (debug/general)
  def rollups_available?
    @rollups_available ||= InsightDetectionRollup
      .where(workspace_id: @workspace_id, logit_margin_min: @logit_margin_min)
      .limit(MIN_ROLLUP_ROWS)
      .count >= MIN_ROLLUP_ROWS
  end

  # Return [min_posted_on, max_posted_on] for current rollup subject and optional metric.
  def date_bounds(metric_id: nil)
    scope = base_rollup_scope
    scope = scope.where(dimension_id: metric_id) if metric_id.present?

    row = scope.pick(Arel.sql("MIN(posted_on)"), Arel.sql("MAX(posted_on)"))
    return [nil, nil] unless row

    [row[0]&.to_date, row[1]&.to_date]
  end

  # Check if rollups exist for the specific subject + date range.
  # Falls back to detections only if this scope is missing.
  def rollups_available_for_range?(start_date:, end_date:, metric_id: nil)
    scope = base_rollup_scope
      .where(posted_on: start_date.to_date..end_date.to_date)

    scope = scope.where(dimension_id: metric_id) if metric_id.present?

    scope.limit(1).exists?
  end

  # Get daily positive/negative/total counts for the date range.
  # Returns: { Date => { pos: N, neg: N, tot: N }, ... }
  def daily_counts(start_date:, end_date:, metric_id: nil)
    start_day = start_date.to_date
    end_day = end_date.to_date

    if rollups_available_for_range?(start_date: start_date, end_date: end_date, metric_id: metric_id)
      rollup_data =
        if @group_id.present?
          # Use Group-level rollups
          daily_counts_from_group_rollups(start_date: start_date, end_date: end_date, metric_id: metric_id)
        else
          # Use Workspace-level rollups
          daily_counts_from_rollups(start_date: start_date, end_date: end_date, metric_id: metric_id)
        end

      # If rollups are partial, fill only missing days from detections instead of
      # re-querying the full range (critical for all-time performance).
      latest_rollup_day = rollup_data.keys.max
      earliest_rollup_day = rollup_data.keys.min

      if latest_rollup_day.nil? || earliest_rollup_day.nil?
        return daily_counts_from_detections(start_date: start_date, end_date: end_date, metric_id: metric_id)
      end

      merged = rollup_data.dup

      if earliest_rollup_day > start_day
        head = daily_counts_from_detections(
          start_date: start_day,
          end_date: earliest_rollup_day - 1.day,
          metric_id: metric_id
        )
        merged.merge!(head)
      end

      if latest_rollup_day < end_day
        tail = daily_counts_from_detections(
          start_date: latest_rollup_day + 1.day,
          end_date: end_day,
          metric_id: metric_id
        )
        merged.merge!(tail)
      end

      merged
    else
      daily_counts_from_detections(start_date: start_date, end_date: end_date, metric_id: metric_id)
    end
  end

  # Get aggregate counts for the entire date range
  # Returns: { pos: N, neg: N, tot: N }
  def aggregate_counts(start_date:, end_date:, metric_id: nil)
    daily = daily_counts(start_date: start_date, end_date: end_date, metric_id: metric_id)
    
    result = { pos: 0, neg: 0, tot: 0 }
    daily.each_value do |counts|
      result[:pos] += counts[:pos].to_i
      result[:neg] += counts[:neg].to_i
      result[:tot] += counts[:tot].to_i
    end
    result
  end

  # Get counts grouped by metric for the date range
  # Returns: { metric_id => { pos: N, neg: N, tot: N }, ... }
  def counts_by_metric(start_date:, end_date:)
    if rollups_available_for_range?(start_date: start_date, end_date: end_date)
      if @group_id.present?
        counts_by_metric_from_group_rollups(start_date: start_date, end_date: end_date)
      else
        counts_by_metric_from_rollups(start_date: start_date, end_date: end_date)
      end
    else
      counts_by_metric_from_detections(start_date: start_date, end_date: end_date)
    end
  end

  private

  # ============================================================
  # Rollup-based queries (fast path)
  # ============================================================

  def daily_counts_from_rollups(start_date:, end_date:, metric_id: nil)
    scope = base_rollup_scope
      .where(posted_on: start_date.to_date..end_date.to_date)

    scope = scope.where(dimension_id: metric_id) if metric_id.present?

    rows = scope
      .group(:posted_on)
      .pluck(
        :posted_on,
        Arel.sql("SUM(positive_count)"),
        Arel.sql("SUM(negative_count)"),
        Arel.sql("SUM(total_count)")
      )

    result = {}
    rows.each do |posted_on, pos, neg, tot|
      result[posted_on.to_date] = { pos: pos.to_i, neg: neg.to_i, tot: tot.to_i }
    end
    result
  end

  def counts_by_metric_from_rollups(start_date:, end_date:)
    rows = base_rollup_scope
      .where(posted_on: start_date.to_date..end_date.to_date)
      .group(:dimension_id)
      .pluck(
        :dimension_id,
        Arel.sql("SUM(positive_count)"),
        Arel.sql("SUM(negative_count)"),
        Arel.sql("SUM(total_count)")
      )

    result = {}
    rows.each do |metric_id, pos, neg, tot|
      result[metric_id] = { pos: pos.to_i, neg: neg.to_i, tot: tot.to_i }
    end
    result
  end

  # ============================================================
  # Group rollup-based queries (fast path for group-filtered views)
  # ============================================================

  def daily_counts_from_group_rollups(start_date:, end_date:, metric_id: nil)
    scope = base_rollup_scope
      .where(posted_on: start_date.to_date..end_date.to_date)

    scope = scope.where(dimension_id: metric_id) if metric_id.present?

    rows = scope
      .group(:posted_on)
      .pluck(
        :posted_on,
        Arel.sql("SUM(positive_count)"),
        Arel.sql("SUM(negative_count)"),
        Arel.sql("SUM(total_count)")
      )

    result = {}
    rows.each do |posted_on, pos, neg, tot|
      result[posted_on.to_date] = { pos: pos.to_i, neg: neg.to_i, tot: tot.to_i }
    end
    result
  end

  def counts_by_metric_from_group_rollups(start_date:, end_date:)
    rows = base_rollup_scope
      .where(posted_on: start_date.to_date..end_date.to_date)
      .group(:dimension_id)
      .pluck(
        :dimension_id,
        Arel.sql("SUM(positive_count)"),
        Arel.sql("SUM(negative_count)"),
        Arel.sql("SUM(total_count)")
      )

    result = {}
    rows.each do |metric_id, pos, neg, tot|
      result[metric_id] = { pos: pos.to_i, neg: neg.to_i, tot: tot.to_i }
    end
    result
  end

  # ============================================================
  # Detection-based queries (fallback path)
  # ============================================================

  def daily_counts_from_detections(start_date:, end_date:, metric_id: nil)
    scope = base_detection_scope
      .where("messages.posted_at >= ? AND messages.posted_at <= ?",
             start_date.to_date.beginning_of_day,
             end_date.to_date.end_of_day)

    if metric_id.present?
      scope = scope
        .joins(signal_category: :submetric)
        .where("COALESCE(detections.metric_id, submetrics.metric_id) = ?", metric_id)
    end

    rows = scope
      .group(Arel.sql("DATE(messages.posted_at)"))
      .pluck(
        Arel.sql("DATE(messages.posted_at)"),
        Arel.sql("SUM(CASE WHEN detections.polarity = 'positive' THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN detections.polarity = 'negative' THEN 1 ELSE 0 END)"),
        Arel.sql("COUNT(*)")
      )

    result = {}
    rows.each do |posted_on, pos, neg, tot|
      result[posted_on.to_date] = { pos: pos.to_i, neg: neg.to_i, tot: tot.to_i }
    end
    result
  end

  def counts_by_metric_from_detections(start_date:, end_date:)
    rows = base_detection_scope
      .joins(signal_category: :submetric)
      .where("messages.posted_at >= ? AND messages.posted_at <= ?",
             start_date.to_date.beginning_of_day,
             end_date.to_date.end_of_day)
      .group(Arel.sql("COALESCE(detections.metric_id, submetrics.metric_id)"))
      .pluck(
        Arel.sql("COALESCE(detections.metric_id, submetrics.metric_id)"),
        Arel.sql("SUM(CASE WHEN detections.polarity = 'positive' THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN detections.polarity = 'negative' THEN 1 ELSE 0 END)"),
        Arel.sql("COUNT(*)")
      )

    result = {}
    rows.each do |metric_id, pos, neg, tot|
      result[metric_id] = { pos: pos.to_i, neg: neg.to_i, tot: tot.to_i }
    end
    result
  end

  def base_detection_scope
    scope = Detection
      .joins(message: :integration)
      .where(integrations: { workspace_id: @workspace_id })
      .merge(Detection.with_scoring_policy)

    if @group_member_ids.present?
      scope = scope.where(messages: { integration_user_id: @group_member_ids })
    end

    scope
  end

  def base_rollup_scope
    scope = InsightDetectionRollup
      .where(workspace_id: @workspace_id, logit_margin_min: @logit_margin_min)
      .where(dimension_type: "metric")

    if @group_id.present?
      scope.where(subject_type: "Group", subject_id: @group_id)
    else
      scope.where(subject_type: "Workspace", subject_id: @workspace_id)
    end
  end
end
