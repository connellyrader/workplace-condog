class AiChat::WidgetsController < ApplicationController
  before_action :authenticate_user!

  # GET /ai_chat/widgets/sparkline
  # Params:
  #   metric       - metric name (string, required)
  #   start_date   - ISO date (required)
  #   end_date     - ISO date (required)
  #   metric_kind  - "pos_rate"|"neg_rate"|"avg_logit"|"total" (optional, default "pos_rate")
  def sparkline
    metric_name  = params[:metric].to_s.strip
    start_date_s = params[:start_date].to_s
    end_date_s   = params[:end_date].to_s
    kind         = (params[:metric_kind].presence || "pos_rate").to_s
    workspace_id = params[:workspace_id]

    metric = Metric.where("LOWER(name) = ?", metric_name.downcase).first
    return head :bad_request unless metric && start_date_s.present? && end_date_s.present?

    from = parse_dateish(start_date_s)
    to   = parse_dateish(end_date_s)
    return head :bad_request unless from && to

    points = AiChat::DataQueries.timeseries(
      user: current_user,
      category: nil,
      from: from.beginning_of_day,
      to:   to.end_of_day,
      metric: kind.to_sym,
      metric_ids: [metric.id],
      workspace_id: workspace_id
    )

    html, _key = AiChat::WidgetRenderer.render(
      kind:   :sparkline,
      user:   current_user,
      params: {
        category: nil,
        metric:   kind,
        start_date: from.to_date,
        end_date:   to.to_date,
        metric_ids: [metric.id],
        workspace_id: workspace_id
      },
      points: points,
      metric: kind,
      title:  "#{metric.name} — #{kind}",
      width:  (ENV["AI_CHAT_SPARK_W"] || 800).to_i,
      height: (ENV["AI_CHAT_SPARK_H"] || 260).to_i
    )

    render html: html.html_safe
  rescue => e
    Rails.logger.error("[AiChat::WidgetsController#sparkline] #{e.class}: #{e.message}")
    head :bad_request
  end

  # GET /ai_chat/widgets/sparkline_chart
  # Params:
  #   metric       - metric name (string, required)
  #   start_date   - ISO date (required)
  #   end_date     - ISO date (required)
  #   metric_kind  - "pos_rate"|"neg_rate"|"avg_logit"|"total" (optional, default "pos_rate")
  def sparkline_chart
    metric_name  = params[:metric].to_s.strip
    start_date_s = params[:start_date].to_s
    end_date_s   = params[:end_date].to_s
    kind         = (params[:metric_kind].presence || "pos_rate").to_s
    workspace_id = params[:workspace_id]

    metric = Metric.where("LOWER(name) = ?", metric_name.downcase).first
    return head :bad_request unless metric && start_date_s.present? && end_date_s.present?

    from = parse_dateish(start_date_s)
    to   = parse_dateish(end_date_s)
    return head :bad_request unless from && to

    series = AiChat::DataQueries.timeseries(
      user: current_user,
      category: nil,
      from: from.beginning_of_day,
      to:   to.end_of_day,
      metric: kind.to_sym,
      metric_ids: [metric.id],
      workspace_id: workspace_id
    )

    values = Array(series).map { |pt| pt[:value] || pt["value"] }.compact.map { |v| (v.to_f * 100.0).round(2) }
    labels = Array(series).map do |pt|
      d = pt[:date] || pt["date"]
      dd = d.is_a?(Date) || d.is_a?(Time) ? d.to_date : (Date.parse(d.to_s) rescue nil)
      dd ? dd.strftime("%-m/%-d") : nil
    end.compact

    html, _key = AiChat::WidgetRenderer.render(
      kind:   :sparkline_chart,
      user:   current_user,
      params: {
        metric:     kind,
        start_date: from.to_date,
        end_date:   to.to_date,
        values:     values,
        labels:     labels
      },
      title:  metric.name
    )

    render html: html.html_safe
  rescue => e
    Rails.logger.error("[AiChat::WidgetsController#sparkline_chart] #{e.class}: #{e.message}")
    head :bad_request
  end

  # GET /ai_chat/widgets/metric_gauge
  # Params:
  #   metric - metric name (string, required)
  #   value  - numeric or string (required)
  #   change - optional delta string or number
  def metric_gauge
    metric_name = params[:metric].to_s.strip
    value       = params[:value]
    change      = params[:change]
    return head :bad_request if metric_name.blank? || value.nil?

    html, _key = AiChat::WidgetRenderer.render(
      kind:   :metric_gauge,
      user:   current_user,
      params: {
        metric: metric_name,
        value:  value,
        change: change
      },
      points: nil,
      metric: nil,
      title:  metric_name
    )

    render html: html.html_safe
  rescue => e
    Rails.logger.error("[AiChat::WidgetsController#metric_gauge] #{e.class}: #{e.message}")
    head :bad_request
  end

  # GET /ai_chat/widgets/period_comparison
  # Params:
  #   metrics              - comma-separated metric names (required)
  #   Either explicit dates:
  #     period_a_start_date, period_a_end_date,
  #     period_b_start_date, period_b_end_date
  #   OR a shorthand window:
  #     - start_date + end_date
  #     - start_date + window_days
  #     - end_date + window_days
  #     - window="last_30_vs_prev_30" (optionally with end_date)
  #   period_a_label       - optional display label for period A
  #   period_b_label       - optional display label for period B
  def period_comparison
    metric_names = params[:metrics].to_s.split(",").map(&:strip).reject(&:blank?)
    return head :bad_request if metric_names.empty?

    workspace_id = params[:workspace_id]
    a_from = parse_dateish(params[:period_a_start_date] || params[:start_date_a])
    a_to   = parse_dateish(params[:period_a_end_date]   || params[:end_date_a])
    b_from = parse_dateish(params[:period_b_start_date] || params[:start_date_b])
    b_to   = parse_dateish(params[:period_b_end_date]   || params[:end_date_b])

    unless a_from && a_to && b_from && b_to
      window_days = params[:window_days].to_i
      shorthand   = params[:window].to_s.downcase
      # Default 30-day window for the common shorthand
      window_days = 30 if window_days <= 0 && shorthand == "last_30_vs_prev_30"

      base_start = parse_dateish(params[:start_date])
      base_end   = parse_dateish(params[:end_date])

      if base_start && base_end
        a_from = base_start
        a_to   = base_end
      elsif base_start && window_days.positive?
        a_from = base_start
        a_to   = (base_start.to_date + (window_days - 1).days)
      elsif base_end && window_days.positive?
        a_to   = base_end
        a_from = (base_end.to_date - (window_days - 1).days)
      elsif window_days.positive? && shorthand == "last_30_vs_prev_30"
        a_to   = Date.current
        a_from = (a_to - (window_days - 1).days)
      end

      if a_from && a_to && window_days <= 0
        window_days = (a_to.to_date - a_from.to_date).to_i + 1
      end

      if a_from && a_to && window_days.positive?
        b_to   = (a_from.to_date - 1.day)
        b_from = (b_to - (window_days - 1).days)
      end
    end

    return head :bad_request unless a_from && a_to && b_from && b_to

    period_a_label = (params[:period_a_label].presence || "Period A").to_s
    period_b_label = (params[:period_b_label].presence || "Period B").to_s

    agg_a = AiChat::DataQueries.window_aggregates(
      user: current_user,
      from: a_from.beginning_of_day,
      to:   a_to.end_of_day,
      group_by: :metric,
      metric_names: metric_names,
      workspace_id: workspace_id
    )

    agg_b = AiChat::DataQueries.window_aggregates(
      user: current_user,
      from: b_from.beginning_of_day,
      to:   b_to.end_of_day,
      group_by: :metric,
      metric_names: metric_names,
      workspace_id: workspace_id
    )

    rows = metric_names.map do |name|
      a_row = AiChat::ToolRouter.find_by_label(agg_a, name)
      b_row = AiChat::ToolRouter.find_by_label(agg_b, name)

      a_rate = a_row && (a_row[:pos_rate] || a_row["pos_rate"])
      b_rate = b_row && (b_row[:pos_rate] || b_row["pos_rate"])

      a_val = AiChat::ToolRouter.format_percent(a_rate)
      b_val = AiChat::ToolRouter.format_percent(b_rate)

      delta_pp =
        if !a_rate.nil? && !b_rate.nil?
          ((b_rate.to_f - a_rate.to_f) * 100.0).round(1)
        end

      direction =
        if delta_pp.nil? || delta_pp.zero?
          "flat"
        elsif delta_pp.positive?
          "up"
        else
          "down"
        end

      delta_label =
        if delta_pp
          format("%+.1f pp", delta_pp)
        else
          nil
        end

      {
        name:      name,
        a:         a_val,
        b:         b_val,
        delta:     delta_label,
        direction: direction
      }
    end

    html, _key = AiChat::WidgetRenderer.render(
      kind:   :period_comparison,
      user:   current_user,
      params: {
        period_a_label: period_a_label,
        period_b_label: period_b_label,
        metrics:        rows
      }
    )

    render html: html.html_safe
  rescue => e
    Rails.logger.error("[AiChat::WidgetsController#period_comparison] #{e.class}: #{e.message}")
    head :bad_request
  end

  # GET /ai_chat/widgets/group_comparison
  # Params:
  #   metric     - metric name (string, required)
  #   start_date - ISO date (required)
  #   end_date   - ISO date (required)
  #   groups     - comma-separated group names; each name is matched against Group records
  def group_comparison
    metric_name  = params[:metric].to_s.strip
    group_labels = params[:groups].to_s.split(",").map(&:strip).reject(&:blank?)
    return head :bad_request if metric_name.blank? || group_labels.empty?

    from = parse_dateish(params[:start_date])
    to   = parse_dateish(params[:end_date])
    return head :bad_request unless from && to

    workspace_id = params[:workspace_id]
    integration_ids = AiChat::DataQueries.integration_ids_for_user(user: current_user, workspace_id: workspace_id)
    return head :bad_request if integration_ids.empty?
    workspace_ids = Integration.where(id: integration_ids).distinct.pluck(:workspace_id)
    return head :bad_request if workspace_ids.empty?

    groups = []
    group_labels.each do |label|
      matching_groups = Group.where(workspace_id: workspace_ids).where("LOWER(name) = ?", label.downcase)
      next if matching_groups.blank?

      member_ids = GroupMember.joins(:integration_user)
                              .where(group_id: matching_groups.select(:id), integration_users: { integration_id: integration_ids })
                              .pluck(:integration_user_id)
                              .uniq
      next if member_ids.blank?

      rows = AiChat::DataQueries.window_aggregates(
        user: current_user,
        from: from.beginning_of_day,
        to:   to.end_of_day,
        group_by: :metric,
        metric_names: [metric_name],
        integration_user_ids: member_ids,
        workspace_id: workspace_id
      )

      row = rows.first
      next unless row

      pos = row[:pos_rate] || row["pos_rate"]
      neg = row[:neg_rate] || row["neg_rate"]
      total = row[:total] || row["total"]

      groups << {
        name:  label,
        pos:   AiChat::ToolRouter.format_percent(pos),
        neg:   AiChat::ToolRouter.format_percent(neg),
        total: total.to_i
      }
    end

    html, _key = AiChat::WidgetRenderer.render(
      kind:   :group_comparison,
      user:   current_user,
      params: {
        metric_name: metric_name,
        groups:      groups
      }
    )

    render html: html.html_safe
  rescue => e
    Rails.logger.error("[AiChat::WidgetsController#group_comparison] #{e.class}: #{e.message}")
    head :bad_request
  end

  # GET /ai_chat/widgets/top_signals
  # Params:
  #   metric      - metric name (string, optional, defaults to all metrics)
  #   start_date  - ISO date (required)
  #   end_date    - ISO date (required)
  #   direction   - "negative"|"positive" (optional, default "negative")
  #   group_by    - "category"|"subcategory" (optional, default "subcategory")
  #   top_n       - integer (optional, default 5)
  def top_signals
    from = parse_dateish(params[:start_date])
    to   = parse_dateish(params[:end_date])
    return head :bad_request unless from && to
    workspace_id = params[:workspace_id]

    direction = (params[:direction].presence || "negative").to_s
    group_by  =
      case params[:group_by].to_s
      when "category"     then :category
      when "subcategory"  then :subcategory
      else :subcategory
      end

    metric_name = params[:metric].to_s.strip
    top_n       = (params[:top_n].presence || 5).to_i
    top_n       = 5 if top_n <= 0

    agg = AiChat::DataQueries.window_aggregates(
      user: current_user,
      from: from.beginning_of_day,
      to:   to.end_of_day,
      group_by: group_by,
      metric_names: metric_name.present? ? [metric_name] : nil,
      workspace_id: workspace_id
    )

    sorted =
      if direction == "positive"
        Array(agg).sort_by { |r| -((r[:pos_rate] || r["pos_rate"] || 0.0).to_f) }
      else
        Array(agg).sort_by { |r| -((r[:neg_rate] || r["neg_rate"] || 0.0).to_f) }
      end

    drivers = sorted.first(top_n)

    html, _key = AiChat::WidgetRenderer.render(
      kind:   :top_signals,
      user:   current_user,
      params: {
        title:     metric_name.present? ? "Top signals for #{metric_name}" : "Top signals",
        direction: direction,
        drivers:   drivers
      }
    )

    render html: html.html_safe
  rescue => e
    Rails.logger.error("[AiChat::WidgetsController#top_signals] #{e.class}: #{e.message}")
    head :bad_request
  end

  # GET /ai_chat/widgets/event_impact
  # Params:
  #   metric     - metric name (string, required)
  #   event_date - ISO date (required)
  #   pre_days   - integer days before (optional, default 14)
  #   post_days  - integer days after (optional, default 14)
  def event_impact
    metric_name = params[:metric].to_s.strip
    event_date  = parse_dateish(params[:event_date])
    return head :bad_request if metric_name.blank? || event_date.nil?
    workspace_id = params[:workspace_id]

    pre_days  = (params[:pre_days].presence  || 14).to_i
    post_days = (params[:post_days].presence || 14).to_i
    pre_days  = 1 if pre_days <= 0
    post_days = 1 if post_days <= 0

    pre_from  = event_date.to_time - pre_days.days
    pre_to    = event_date.to_time - 1.second
    post_from = event_date.to_time
    post_to   = event_date.to_time + post_days.days

    before_rows = AiChat::DataQueries.window_aggregates(
      user: current_user,
      from: pre_from,
      to:   pre_to,
      group_by: :metric,
      metric_names: [metric_name],
      workspace_id: workspace_id
    )

    after_rows = AiChat::DataQueries.window_aggregates(
      user: current_user,
      from: post_from,
      to:   post_to,
      group_by: :metric,
      metric_names: [metric_name],
      workspace_id: workspace_id
    )

    before_row = before_rows.first
    after_row  = after_rows.first

    before_rate = before_row && (before_row[:pos_rate] || before_row["pos_rate"])
    after_rate  = after_row && (after_row[:pos_rate]  || after_row["pos_rate"])

    comparison = []
    if before_rate || after_rate
      delta_pp =
        if !before_rate.nil? && !after_rate.nil?
          ((after_rate.to_f - before_rate.to_f) * 100.0).round(1)
        end

      comparison << {
        metric: metric_name,
        before: { pos_rate: before_rate },
        after:  { pos_rate: after_rate },
        delta_pos_pp: delta_pp
      }
    end

    html, _key = AiChat::WidgetRenderer.render(
      kind:   :event_impact,
      user:   current_user,
      params: {
        metric_name: metric_name,
        event_date:  event_date.to_date.to_s,
        before_label: "#{pre_days} days before",
        after_label:  "#{post_days} days after",
        comparison:   comparison
      }
    )

    render html: html.html_safe
  rescue => e
    Rails.logger.error("[AiChat::WidgetsController#event_impact] #{e.class}: #{e.message}")
    head :bad_request
  end

  # GET /ai_chat/widgets/aggregate_gauge
  # Params:
  #   metric                   - metric name (string, required)
  #   Either:
  #     - start_date + end_date
  #     - start_date + window_days
  #     - end_date   + window_days
  #     - window="last_30_vs_prev_30" (optionally with end_date)
  #   comparison_start_date    - ISO date (optional; if absent, previous same-length window is used)
  #   comparison_end_date      - ISO date (optional)
  #   notch1, notch2, reversed - optional gauge configuration
  def aggregate_gauge
    metric_name = params[:metric].to_s.strip
    from        = parse_dateish(params[:start_date])
    to          = parse_dateish(params[:end_date])
    workspace_id = params[:workspace_id]

    unless from && to
      window_days = params[:window_days].to_i
      shorthand   = params[:window].to_s.downcase
      window_days = 30 if window_days <= 0 && shorthand == "last_30_vs_prev_30"

      if from && window_days.positive? && to.nil?
        to = (from.to_date + (window_days - 1).days)
      elsif to && window_days.positive? && from.nil?
        from = (to.to_date - (window_days - 1).days)
      elsif window_days.positive? && shorthand == "last_30_vs_prev_30"
        to   = Date.current
        from = (to - (window_days - 1).days)
      end
    end

    return head :bad_request if metric_name.blank? || from.nil? || to.nil?

    main_rows = AiChat::DataQueries.window_aggregates(
      user: current_user,
      from: from.beginning_of_day,
      to:   to.end_of_day,
      group_by: :metric,
      metric_names: [metric_name],
      workspace_id: workspace_id
    )

    main_row  = main_rows.first
    main_rate = main_row && (main_row[:pos_rate] || main_row["pos_rate"])
    value_pct = main_rate ? (main_rate.to_f * 100.0).round(1) : nil

    comp_from =
      if params[:comparison_start_date].present?
        parse_dateish(params[:comparison_start_date])
      else
        window_days = (to.to_date - from.to_date).to_i + 1
        to.to_date - window_days.days
      end
    comp_to =
      if params[:comparison_end_date].present?
        parse_dateish(params[:comparison_end_date])
      else
        from.to_date - 1.day
      end

    comp_rate = nil
    if comp_from && comp_to && comp_from <= comp_to
      comp_rows = AiChat::DataQueries.window_aggregates(
        user: current_user,
        from: comp_from.beginning_of_day,
        to:   comp_to.end_of_day,
        group_by: :metric,
        metric_names: [metric_name],
        workspace_id: workspace_id
      )
      comp_row  = comp_rows.first
      comp_rate = comp_row && (comp_row[:pos_rate] || comp_row["pos_rate"])
    end

    trend_delta =
      if !main_rate.nil? && !comp_rate.nil?
        ((main_rate.to_f - comp_rate.to_f) * 100.0).round(1)
      else
        0.0
      end

    range_phrase = "#{from.to_date} – #{to.to_date}"

    html, _key = AiChat::WidgetRenderer.render(
      kind:   :aggregate_gauge,
      user:   current_user,
      params: {
        metric_name:  metric_name,
        value:        value_pct,
        trend_delta:  trend_delta,
        range_phrase: range_phrase,
        notch1:       params[:notch1],
        notch2:       params[:notch2],
        reversed:     params[:reversed].to_s == "true"
      }
    )

    render html: html.html_safe
  rescue => e
    Rails.logger.error("[AiChat::WidgetsController#aggregate_gauge] #{e.class}: #{e.message}")
    head :bad_request
  end

  private

  def parse_dateish(v)
    return v if v.is_a?(Date)
    return v.to_date if v.respond_to?(:to_date)
    return nil if v.blank?
    Date.parse(v.to_s)
  rescue
    nil
  end
end
