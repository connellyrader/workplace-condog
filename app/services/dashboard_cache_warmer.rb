# frozen_string_literal: true

class DashboardCacheWarmer
  PRESETS = %w[last_30 last_60 last_90 ytd last_year all_time].freeze

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def warm!(workspace:, group: nil)
    return if workspace.archived_at.present?

    wid = workspace.id
    group_member_ids = group&.integration_user_ids
    group_scope = group ? "group:#{group.id}" : "all"

    days_analyzed = Integration.where(workspace_id: wid).maximum(:days_analyzed).to_i
    metrics = Metric.order(:sort).to_a

    warm_last100(wid:, group_scope:, group_member_ids:)

    PRESETS.each do |preset|
      range_start, range_end, is_all_time = resolve_range(workspace:, group:, preset:)
      next unless range_start && range_end

      days = (range_end - range_start).to_i + 1
      service = DashboardRollupService.new(
        workspace_id: wid,
        group_member_ids: group_member_ids,
        group_id: group&.id
      )

      series_start = range_start - 29.days
      daily = normalize_daily(service.daily_counts(start_date: series_start, end_date: range_end))
      anchors = spark_anchor_days(range_start, range_end)
      pts = rolling30_points(daily, range_start, range_end, anchors)
      pts = [pts.first, pts.first] if pts.size < 2

      metric_counts = service.counts_by_metric(start_date: range_start, end_date: range_end)
      metric_card_data = build_metric_card_data(
        metrics: metrics,
        metric_counts: metric_counts,
        days_analyzed: days_analyzed,
        range_start: range_start,
        range_end: range_end,
        service: service,
        is_all_time: is_all_time
      )

      ["html", "json"].each do |fmt|
        cache_key = [
          "dash-index-v4",
          wid,
          range_start.to_date,
          range_end.to_date,
          group_scope,
          is_all_time ? 1 : 0,
          fmt
        ].join(":")

        Rails.cache.write(
          cache_key,
          {
            spark_points: pts,
            metric_counts: metric_counts,
            metric_card_data: metric_card_data
          },
          expires_in: dashboard_cache_ttl(days: days, is_json: (fmt == "json"))
        )
      end
    end
  rescue => e
    @logger.error("[DashboardCacheWarm] workspace=#{workspace.id} group=#{group&.id || 'all'} error=#{e.class} #{e.message}")
  end

  private

  def warm_last100(wid:, group_scope:, group_member_ids:)
    scope = Detection
      .joins(message: :integration)
      .where(integrations: { workspace_id: wid })
      .merge(Detection.with_scoring_policy)

    if group_member_ids.present?
      scope = scope.where(messages: { integration_user_id: group_member_ids })
    end

    message_window = (ENV["LAST100_MESSAGE_WINDOW"] || "500").to_i
    message_window = 200 if message_window < 200

    recent_message_ids =
      scope
      .group("messages.id")
      .reorder(Arel.sql("MAX(messages.posted_at) DESC"))
      .limit(message_window)
      .pluck(Arel.sql("messages.id"))

    last100 = if recent_message_ids.empty?
      []
    else
      scope
        .where(detections: { message_id: recent_message_ids })
        .includes(message: :channel, signal_category: { submetric: :metric })
        .reorder(Arel.sql("messages.posted_at DESC, detections.created_at DESC"))
        .limit(100)
        .to_a
        .reverse
    end

    Rails.cache.write(["dash-last100-v2", wid, group_scope].join(":"), last100, expires_in: 45.seconds)
  end

  def resolve_range(workspace:, group:, preset:)
    today = Time.zone.today

    case preset
    when "last_30" then [today - 29.days, today, false]
    when "last_60" then [today - 59.days, today, false]
    when "last_90" then [today - 89.days, today, false]
    when "last_year"
      last_year_end = today.beginning_of_year - 1.day
      [last_year_end.beginning_of_year, last_year_end, false]
    when "ytd" then [today.beginning_of_year, today, false]
    when "all_time"
      service = DashboardRollupService.new(workspace_id: workspace.id, group_member_ids: group&.integration_user_ids, group_id: group&.id)
      min_rollup_day, max_rollup_day = service.date_bounds
      if min_rollup_day && max_rollup_day
        [min_rollup_day, [max_rollup_day, today].min, true]
      else
        [Date.new(2000, 1, 1), today, true]
      end
    end
  end

  def normalize_daily(raw)
    out = Hash.new { |h, k| h[k] = { pos: 0, tot: 0 } }
    raw.each { |d, c| out[d.to_date] = { pos: c[:pos].to_i, tot: c[:tot].to_i } }
    out
  end

  def spark_anchor_days(start_day, end_day)
    span = (end_day - start_day).to_i + 1
    step = if span <= 45
      1
    elsif span <= 180
      7
    elsif span <= 730
      14
    else
      30
    end

    out = []
    d = start_day.to_date
    while d <= end_day.to_date
      out << d
      d += step.days
    end
    out << end_day.to_date unless out.last == end_day.to_date
    out.uniq
  end

  def rolling30_points(daily, range_start, range_end, anchors)
    lookback_day = range_start.to_date - 29.days
    days_series = (lookback_day..range_end.to_date).to_a

    idx = {}
    cum_pos = Array.new(days_series.size + 1, 0)
    cum_tot = Array.new(days_series.size + 1, 0)

    days_series.each_with_index do |dd, i|
      idx[dd] = i
      cum_pos[i + 1] = cum_pos[i] + daily[dd][:pos].to_i
      cum_tot[i + 1] = cum_tot[i] + daily[dd][:tot].to_i
    end

    rolling90 = lambda do |end_day|
      end_day = end_day.to_date
      start_day = [end_day - 29.days, lookback_day].max
      si = idx[start_day]
      ei = idx[end_day]
      if si.nil? || ei.nil? || ei < si
        50.0
      else
        pos = cum_pos[ei + 1] - cum_pos[si]
        tot = cum_tot[ei + 1] - cum_tot[si]
        tot > 0 ? (pos.to_f / tot.to_f) * 100.0 : 50.0
      end
    end

    anchors.map { |ad| rolling90.call(ad).round }
  end

  def build_metric_card_data(metrics:, metric_counts:, days_analyzed:, range_start:, range_end:, service:, is_all_time:)
    min_detections = Clara::OverviewService::MIN_DETECTIONS
    enough_data = days_analyzed.to_i >= 30

    metrics.each_with_object({}) do |metric, out|
      daily = normalize_daily(
        service.daily_counts(start_date: range_start - 29.days, end_date: range_end, metric_id: metric.id)
      )

      anchors = spark_anchor_days(range_start, range_end)
      points = rolling30_series(daily, range_start, range_end, anchors, reverse: metric.reverse?)[:points].map(&:round)
      points = [points.first, points.first] if points.size < 2

      curr_count = (metric_counts || {})[metric.id].to_h[:tot].to_i
      score_available = enough_data && curr_count >= min_detections
      metric_delta = (score_available && !is_all_time) ? (points.last.to_i - points.first.to_i) : 0

      if metric.reverse?
        arrow_dir = metric_delta > 0 ? "up" : "down"
        color_dir = metric_delta > 0 ? "down" : "up"
      else
        arrow_dir = metric_delta >= 0 ? "up" : "down"
        color_dir = metric_delta >= 0 ? "up" : "down"
      end

      out[metric.id] = {
        points: points,
        score_int: points.last.to_i,
        score_available: score_available,
        metric_delta: metric_delta,
        metric_delta_abs: metric_delta.abs,
        arrow_dir: arrow_dir,
        color_dir: color_dir,
        show_trend: score_available && !is_all_time,
        has_any_data: curr_count.positive?,
        enough_data: enough_data
      }
    end
  end

  def rolling30_series(daily, range_start, range_end, anchors, reverse: false)
    start_day = range_start.to_date
    end_day   = range_end.to_date
    anchors   = Array(anchors).map(&:to_date)

    lookback_start = start_day - 29.days
    days = (lookback_start..end_day).to_a
    idx = {}
    cum_pos = Array.new(days.size + 1, 0)
    cum_tot = Array.new(days.size + 1, 0)

    days.each_with_index do |d, i|
      idx[d] = i
      pos = daily[d][:pos] rescue 0
      tot = daily[d][:tot] rescue 0
      cum_pos[i + 1] = cum_pos[i] + pos.to_i
      cum_tot[i + 1] = cum_tot[i] + tot.to_i
    end

    rolling = ->(end_d) do
      end_d = end_d.to_date
      s = [end_d - 29.days, lookback_start].max
      si = idx[s]
      ei = idx[end_d]
      return 50.0 if si.nil? || ei.nil? || ei < si

      pos = cum_pos[ei + 1] - cum_pos[si]
      tot = cum_tot[ei + 1] - cum_tot[si]
      pct = tot > 0 ? (pos.to_f / tot.to_f) * 100.0 : 50.0
      pct = 100.0 - pct if reverse
      pct
    end

    { start_score: rolling.call(start_day), end_score: rolling.call(end_day), points: anchors.map { |d| rolling.call(d) } }
  end

  def dashboard_cache_ttl(days:, is_json: false)
    ttl =
      if days <= 45
        45.seconds
      elsif days <= 120
        90.seconds
      elsif days <= 365
        3.minutes
      else
        5.minutes
      end

    return ttl unless is_json

    (ttl.to_i * 1.5).to_i.seconds
  end
end
