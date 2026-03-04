# frozen_string_literal: true

module AiChat
  class ToolRouter
    DEFAULT_TOPLINE_METRIC_LIMIT = (ENV["AI_CHAT_TOPLINE_METRIC_LIMIT"] || "6").to_i
    MAX_SERIES_FOR_BUNDLE       = (ENV["AI_CHAT_MAX_TIMESERIES_SERIES"] || "4").to_i

    # -------- general helpers --------

    # Parse a date/time-ish value sensibly; fall back to now if parsing fails.
    def self.iso!(v)
      return v.to_time if v.respond_to?(:to_time)
      return Time.zone.parse(v.to_s) if defined?(Time) && Time.respond_to?(:zone) && Time.zone
      Time.parse(v.to_s)
    rescue
      Time.now
    end


    def self.build_timeseries_bundle(args, user:)
      a = args.deep_dup
      from, to = window_from_args(a)
      metric_kind = (a["metric"] || "pos_rate").to_sym
      cadence = (a["cadence"] || "day").to_s
      limit = a["top_n"].to_i
      limit = MAX_SERIES_FOR_BUNDLE if limit <= 0
      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      specs = bundle_series_specs(a, fallback_limit: limit).first(limit)
      filters = {
        workspace_id: a["workspace_id"],
        min_logit_margin: min_logit

      }

      width  = (ENV["AI_CHAT_SPARK_W"] || 800).to_i
      height = (ENV["AI_CHAT_SPARK_H"] || 260).to_i

      series_entries = []
      insights = []
      blocks = []

      specs.each do |spec|
        info = metric_info_for(spec[:metric_ids])
        default_label = if spec[:metric_ids].present?
          info[spec[:metric_ids].first]&.dig(:name)
        elsif spec[:category].present?
          spec[:category]
        else
          "Series"
        end

        label = spec[:label].presence || default_label || "Series"

        ts = series_from_timeseries(user: user, filters: filters, spec: spec, from: from, to: to, metric_kind: metric_kind, cadence: cadence)
        points = ts[:points]

        latest = points.reverse.find { |pt| !pt[:value].nil? }
        earliest = points.find { |pt| !pt[:value].nil? }

        delta_value = if latest && earliest
          change = latest[:value].to_f - earliest[:value].to_f
          metric_kind == :total ? change.round(0) : (change * 100.0).round(1)
        end

        insights << {
          label: label,
          latest: latest&.dig(:value),
          change: delta_value,
          trend: delta_label(metric_kind == :total ? delta_value : delta_value)
        }

        series_entries << {
          label: label,
          metric_ids: spec[:metric_ids],
          category: spec[:category],
          points: points,
          latest_value: latest&.dig(:value),
          change: delta_value,
          cadence: cadence
        }

        html, key = AiChat::WidgetRenderer.render(
          kind: :sparkline,
          user: user,
          params: ts[:params],
          points: points,
          metric: metric_kind,
          title: "#{label} — #{metric_kind_label(metric_kind)}",
          width: width,
          height: height
        )

        blocks << {
          "type" => "widget",
          "kind" => "sparkline",
          "title" => "#{label} — #{metric_kind_label(metric_kind)}",
          "key" => key,
          "params" => ts[:params],
          "html" => html
        }
      end

      if series_entries.any?
        table_rows = series_entries.map do |entry|
          latest_val = entry[:latest_value]
          latest_fmt = metric_kind == :total ? latest_val.to_i : format_percent(latest_val)
          change_val = entry[:change]
          change_fmt = if change_val.nil?
            "—"
          elsif metric_kind == :total
            format("%+d", change_val.to_i)
          else
            format("%+.1f pp", change_val)
          end

          [entry[:label], latest_fmt, change_fmt]
        end

        blocks << {
          "type" => "table",
          "title" => "Trend snapshot",
          "columns" => ["Series","Latest","Δ vs window start"],
          "rows" => table_rows
        }
      end

      {
        window: window_hash(from, to),
        metric: metric_kind_label(metric_kind),
        cadence: cadence,
        series: series_entries,
        insights: insights,
        blocks: blocks
      }
    end

    def self.build_driver_breakdown(args, user:)
      a = args.deep_dup
      from, to = window_from_args(a)
      group = (a["group_by"] || "subcategory").to_sym
      top_n = a["top_n"].to_i
      top_n = 5 if top_n <= 0

      metric_ids = metric_ids_from_args(a, fallback_limit: 1)
      filters = {
        workspace_id: a["workspace_id"],
        categories: Array(a["categories"]).presence,
        category_ids: Array(a["category_ids"]).presence,
        submetric_ids: Array(a["submetric_ids"]).presence,
        subcategory_ids: Array(a["subcategory_ids"]).presence
      }.compact

      agg = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: group,
        metric_ids: metric_ids,
        **filters
      )

      sorted = Array(agg).sort_by { |row| -((row[:neg_rate] || row["neg_rate"] || 0.0).to_f) }
      drivers = sorted.first(top_n)

      rows = drivers.map do |row|
        label = row[:label] || row["label"] || row[:category] || row["category"]
        total = row[:total] || row["total"]
        pos = row[:pos_rate] || row["pos_rate"]
        neg = row[:neg_rate] || row["neg_rate"]
        [label, total.to_i, format_percent(pos), format_percent(neg)]
      end

      bullets = drivers.map do |row|
        label = row[:label] || row["label"] || row[:category]
        neg = row[:neg_rate] || row["neg_rate"]
        total = row[:total] || row["total"]
        "**#{label}** — #{format_percent(neg)} negative across #{total} signals."
      end

      blocks = []
      if rows.any?
        blocks << {
          "type" => "table",
          "title" => "Drivers dragging the metric",
          "columns" => [group.to_s.capitalize, "Signals","Positive %","Negative %"],
          "rows" => rows
        }
      end
      if bullets.any?
        blocks << { "type" => "bullets", "title" => "What's driving the pattern", "items" => bullets }
      end

      {
        window: window_hash(from, to),
        metric_ids: metric_ids,
        group_by: group,
        drivers: drivers,
        blocks: blocks
      }
    end

    def self.build_segment_compare(args, user:)
      a = args.deep_dup
      from, to = window_from_args(a)
      metric_ids = metric_ids_from_args(a, fallback_limit: 1)
      metric_info = metric_info_for(metric_ids)
      segments_input = Array(a["segments"])
      return { error: "segments_required" } if segments_input.blank?

      filters = {
        workspace_id: a["workspace_id"],
        categories: Array(a["categories"]).presence,
        category_ids: Array(a["category_ids"]).presence,
        submetric_ids: Array(a["submetric_ids"]).presence,
        subcategory_ids: Array(a["subcategory_ids"]).presence
      }.compact

      target_label = metric_info[metric_ids.first]&.dig(:name)

      segments = []
      segments_input.each_with_index do |seg, idx|
        next unless seg.is_a?(Hash)
        label = seg["label"].presence || "Group #{idx + 1}"

        group_ids   = Array(seg["group_ids"])
        group_names = Array(seg["group_names"].presence || [label])
        member_ids  = integration_user_ids_for_groups(group_ids: group_ids, group_names: group_names, user: user, workspace_id: a["workspace_id"])
        next if member_ids.blank?

        stats = AiChat::DataQueries.window_aggregates(
          user: user,
          from: from,
          to: to,
          group_by: :metric,
          metric_ids: metric_ids,
          integration_user_ids: member_ids,
          **filters
        )

        stat = target_label ? find_by_label(stats, target_label) : stats.first
        next unless stat

        pos_rate = stat[:pos_rate] || stat["pos_rate"]
        neg_rate = stat[:neg_rate] || stat["neg_rate"]
        total = stat[:total] || stat["total"]

        segments << {
          label: label,
          integration_user_ids: member_ids,
          workspace_user_ids: member_ids, # legacy alias
          total: total.to_i,
          pos_rate: pos_rate,
          neg_rate: neg_rate
        }
      end

      return { error: "segments_not_found" } if segments.blank?

      segments.sort_by! { |seg| -seg[:pos_rate].to_f }

      table_rows = segments.map do |seg|
        [seg[:label], format_percent(seg[:pos_rate]), format_percent(seg[:neg_rate]), seg[:total]]
      end

      blocks = []
      if table_rows.any?
        blocks << {
          "type" => "table",
          "title" => "Segment comparison",
          "columns" => ["Segment","Positive %","Negative %","Signals"],
          "rows" => table_rows
        }
      end

      if segments.size >= 2
        best = segments.first
        worst = segments.last
        gap = ((best[:pos_rate].to_f - worst[:pos_rate].to_f) * 100.0).round(1)
        blocks << {
          "type" => "callout",
          "title" => "Gap highlight",
          "text" => "#{best[:label]} leads #{worst[:label]} by #{gap.abs} percentage points of positive sentiment."
        }
      end

      {
        window: window_hash(from, to),
        metric_ids: metric_ids,
        segments: segments,
        blocks: blocks
      }
    end

    def self.build_event_window_compare(args, user:)
      return { error: "event_date_required" } if args["event_date"].blank?
      event = iso!(args["event_date"])
      pre_days = [args["pre_days"].to_i, 1].max
      post_days = [args["post_days"].to_i, 1].max

      pre_from = event - pre_days.days
      pre_to   = event - 1.second
      post_from = event
      post_to   = event + post_days.days

      metric_ids = metric_ids_from_args(args)
      metric_info = metric_info_for(metric_ids)
      filters = {
        workspace_id: args["workspace_id"],
        categories: Array(args["categories"]).presence,
        category_ids: Array(args["category_ids"]).presence,
        submetric_ids: Array(args["submetric_ids"]).presence,
        subcategory_ids: Array(args["subcategory_ids"]).presence
      }.compact

      before_rows = AiChat::DataQueries.window_aggregates(
        user: user,
        from: pre_from,
        to: pre_to,
        group_by: :metric,
        metric_ids: metric_ids,
        **filters
      )

      after_rows = AiChat::DataQueries.window_aggregates(
        user: user,
        from: post_from,
        to: post_to,
        group_by: :metric,
        metric_ids: metric_ids,
        **filters
      )

      comparison = metric_ids.map do |mid|
        info = metric_info[mid]
        label = info&.dig(:name) || "Metric #{mid}"
        before = find_by_label(before_rows, label) || {}
        after  = find_by_label(after_rows, label) || {}
        before_pos = before[:pos_rate] || before["pos_rate"]
        after_pos  = after[:pos_rate] || after["pos_rate"]
        delta_pp = if before_pos.nil? || after_pos.nil?
          nil
        else
          ((after_pos.to_f - before_pos.to_f) * 100.0).round(1)
        end

        {
          metric_id: mid,
          metric: label,
          before: before,
          after: after,
          delta_pos_pp: delta_pp
        }
      end

      rows = comparison.map do |row|
        [
          row[:metric],
          format_percent(row[:before][:pos_rate] || row[:before]["pos_rate"]),
          format_percent(row[:after][:pos_rate] || row[:after]["pos_rate"]),
          (row[:delta_pos_pp] ? format("%+.1f pp", row[:delta_pos_pp]) : "—")
        ]
      end

      blocks = []
      if rows.any?
        blocks << {
          "type" => "table",
          "title" => "Before vs after",
          "columns" => ["Metric","Before","After","Δ"],
          "rows" => rows
        }
      end

      {
        event_date: event.to_date,
        before_window: window_hash(pre_from, pre_to),
        after_window: window_hash(post_from, post_to),
        comparison: comparison,
        blocks: blocks
      }
    end

    def self.build_root_cause_detector(args, user:)
      a = args.deep_dup
      from, to = window_from_args(a)
      lookback_days = a["lookback_days"].to_i
      lookback_days = [(to.to_date - from.to_date).to_i, 7].max if lookback_days <= 0

      prior_to = from - 1.second
      prior_from = prior_to - lookback_days.days

      metric_ids = metric_ids_from_args(a, fallback_limit: 1)
      top_n = a["top_n"].to_i
      top_n = 5 if top_n <= 0

      filters = {
        workspace_id: a["workspace_id"],
        categories: Array(a["categories"]).presence,
        category_ids: Array(a["category_ids"]).presence
      }.compact

      current = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: :category,
        metric_ids: metric_ids,
        **filters
      )

      prior = AiChat::DataQueries.window_aggregates(
        user: user,
        from: prior_from,
        to: prior_to,
        group_by: :category,
        metric_ids: metric_ids,
        **filters
      )

      prior_map = {}
      Array(prior).each do |row|
        prior_map[downcase_label(row[:label] || row["label"])] = row
      end

      deltas = Array(current).map do |row|
        label = row[:label] || row["label"] || row[:category]
        key = downcase_label(label)
        prev = prior_map[key] || {}
        curr_pos = row[:pos_rate] || row["pos_rate"]
        prev_pos = prev[:pos_rate] || prev["pos_rate"]
        delta = if curr_pos && prev_pos
          ((curr_pos.to_f - prev_pos.to_f) * 100.0).round(1)
        end
        {
          label: label,
          total: row[:total] || row["total"],
          pos_rate: curr_pos,
          neg_rate: row[:neg_rate] || row["neg_rate"],
          delta_pos_pp: delta
        }
      end

      ranked = deltas.sort_by { |r| r[:delta_pos_pp].to_f }
      focus = ranked.first(top_n)

      rows = focus.map do |r|
        delta_fmt = r[:delta_pos_pp] ? format("%+.1f pp", r[:delta_pos_pp]) : "—"
        [r[:label], r[:total].to_i, format_percent(r[:pos_rate]), delta_fmt]
      end

      bullets = focus.map do |r|
        next unless r[:delta_pos_pp]
        trend = r[:delta_pos_pp] < 0 ? "worsened" : "improved"
        "**#{r[:label]}** #{trend} by #{r[:delta_pos_pp].abs.round(1)} pp across #{r[:total]} signals."
      end.compact

      blocks = []
      if rows.any?
        blocks << {
          "type" => "table",
          "title" => "Emerging signals",
          "columns" => ["Category","Signals","Positive %","Δ vs prior"],
          "rows" => rows
        }
      end
      blocks << { "type" => "bullets", "title" => "Why it's happening", "items" => bullets } if bullets.any?

      {
        window: window_hash(from, to),
        comparison_window: window_hash(prior_from, prior_to),
        metric_ids: metric_ids,
        signals: focus,
        blocks: blocks
      }
    end

    def self.rolling_30d_window_from_end(end_dateish)
      end_time = iso!(end_dateish).end_of_day
      start_time = (end_time.to_date - 29).beginning_of_day
      [start_time, end_time]
    end

    # Mirror DashboardController#spark_anchor_days exactly.
    def self.dashboard_anchor_days(start_day, end_day)
      start_day = start_day.to_date
      end_day   = end_day.to_date
      span = (end_day - start_day).to_i + 1

      step =
        if span <= 45
          1
        elsif span <= 180
          7
        elsif span <= 730
          14
        else
          30
        end

      out = []
      d = start_day
      while d <= end_day
        out << d
        d += step.days
      end
      out << end_day unless out.last == end_day
      out.uniq
    end

    # Mirror DashboardController#rolling30_series exactly.
    def self.dashboard_rolling30_series(daily, range_start, range_end, anchors, reverse: false)
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
        s = end_d - 29.days
        s = [s, lookback_start].max

        si = idx[s]
        ei = idx[end_d]
        return 50.0 if si.nil? || ei.nil? || ei < si

        pos = cum_pos[ei + 1] - cum_pos[si]
        tot = cum_tot[ei + 1] - cum_tot[si]
        pct = tot > 0 ? (pos.to_f / tot.to_f) * 100.0 : 50.0
        pct = 100.0 - pct if reverse
        pct
      end

      points = anchors.map { |d| rolling.call(d) }
      { start_score: rolling.call(start_day), end_score: rolling.call(end_day), points: points }
    end

    def self.dashboard_window_score(service, start_date, end_date, metric_id:, reverse: false)
      anchors = dashboard_anchor_days(start_date, end_date)
      daily = service.daily_counts(start_date: start_date - 29.days, end_date: end_date, metric_id: metric_id)
      series = dashboard_rolling30_series(daily, start_date, end_date, anchors, reverse: reverse)
      points = series[:points].map(&:round)
      points = [points.first, points.first] if points.size < 2
      points.last.to_i
    end

    # Dashboard-aligned score calculation for submetric/signal_category scopes.
    # Falls back to DataQueries when rollups don't support the scope.
    def self.dashboard_aligned_score(user:, workspace_id:, start_date:, end_date:, 
                                     metric_id: nil, submetric_id: nil, signal_category_id: nil, 
                                     integration_user_ids: nil, group_id: nil,
                                     min_logit_margin: nil)
      min_logit = (min_logit_margin.presence || ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      # For metric-level scopes, use DashboardRollupService directly
      if metric_id.present? && submetric_id.blank? && signal_category_id.blank?
        service = DashboardRollupService.new(
          workspace_id: workspace_id,
          logit_margin_min: min_logit,
          group_member_ids: integration_user_ids,
          group_id: group_id
        )
        
        metric = Metric.find_by(id: metric_id)
        reverse = metric&.reverse? || false
        score = dashboard_window_score(service, start_date, end_date, metric_id: metric_id, reverse: reverse)
        counts = service.aggregate_counts(start_date: start_date, end_date: end_date, metric_id: metric_id)
        
        return {
          score: score,
          detections: counts[:tot].to_i,
          ok: counts[:tot].to_i >= 3
        }
      end

      # For submetric/signal_category scopes, compute dashboard-style rolling score from daily pos/tot.
      # This mirrors DashboardController metric page logic for submetric/signal rows.
      lookback_start = start_date.to_date - 29.days
      window_start_day = end_date.to_date - 29.days
      window_end_day   = end_date.to_date

      scope = Detection
        .joins(message: :integration)
        .where(integrations: { workspace_id: workspace_id })
        .where("messages.posted_at >= ? AND messages.posted_at <= ?", lookback_start.beginning_of_day, end_date.to_date.end_of_day)
        .merge(Detection.with_scoring_policy)

      if integration_user_ids.present?
        scope = scope.where(messages: { integration_user_id: integration_user_ids })
      end

      reverse = false

      if submetric_id.present?
        scope = scope.joins(signal_category: :submetric).where(submetrics: { id: submetric_id })
        reverse = Submetric.joins(:metric).where(submetrics: { id: submetric_id }).pick("metrics.reverse") || false
      elsif signal_category_id.present?
        scope = scope.joins(signal_category: { submetric: :metric }).where(signal_categories: { id: signal_category_id })
        reverse = SignalCategory.joins(submetric: :metric).where(signal_categories: { id: signal_category_id }).pick("metrics.reverse") || false
      end

      rows = scope
        .group(Arel.sql("DATE(messages.posted_at)"))
        .pluck(
          Arel.sql("DATE(messages.posted_at)"),
          Arel.sql("SUM(CASE WHEN detections.polarity = 'positive' THEN 1 ELSE 0 END)"),
          Arel.sql("COUNT(*)")
        )

      daily = Hash.new { |h, k| h[k] = { pos: 0, tot: 0 } }
      rows.each do |day, pos, tot|
        d = day.to_date
        daily[d][:pos] = pos.to_i
        daily[d][:tot] = tot.to_i
      end

      series = dashboard_rolling30_series(daily, start_date.to_date, end_date.to_date, [end_date.to_date], reverse: reverse)
      score = series[:end_score].round

      detections = 0
      (window_start_day..window_end_day).each do |dd|
        detections += daily[dd][:tot].to_i
      end

      {
        score: (detections >= 3 ? score : nil),
        detections: detections,
        ok: detections >= 3
      }
    end

    # =========================================================================
    # global_score - dashboard-aligned scores/deltas (same math as dashboard cards)
    # =========================================================================
    def self.build_global_score(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] global_score args=#{a.inspect} user_id=#{user.id}")

      end_date = a["end_date"].presence || Time.zone.now
      from, to = rolling_30d_window_from_end(end_date)
      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      group_member_ids = integration_user_ids_from_group!(a, user: user)
      return group_member_ids if group_member_ids.is_a?(Hash) && group_member_ids[:error].present?

      workspace_id = a["workspace_id"]
      group_id = a["group_id"].to_i
      group_id = nil if group_id <= 0

      service = DashboardRollupService.new(
        workspace_id: workspace_id,
        logit_margin_min: min_logit,
        group_member_ids: group_member_ids,
        group_id: group_id
      )

      anchors = dashboard_anchor_days(from.to_date, to.to_date)
      overall_daily = service.daily_counts(start_date: from.to_date - 29.days, end_date: to.to_date)
      overall_series = dashboard_rolling30_series(overall_daily, from.to_date, to.to_date, anchors, reverse: false)
      overall_points = overall_series[:points].map(&:round)
      overall_points = [overall_points.first, overall_points.first] if overall_points.size < 2
      global_counts = service.aggregate_counts(start_date: from.to_date, end_date: to.to_date)

      days_analyzed = Integration.joins(:workspace)
                                 .where(workspace_id: workspace_id)
                                 .where(workspaces: { archived_at: nil })
                                 .maximum(:days_analyzed).to_i
      min_detections = Clara::OverviewService::MIN_DETECTIONS
      enough_data = days_analyzed >= 30

      metric_scores = []
      Metric.order(:name).find_each do |metric|
        daily = service.daily_counts(start_date: from.to_date - 29.days, end_date: to.to_date, metric_id: metric.id)
        series = dashboard_rolling30_series(daily, from.to_date, to.to_date, anchors, reverse: metric.reverse?)
        points = series[:points].map(&:round)
        points = [points.first, points.first] if points.size < 2

        curr_counts = service.aggregate_counts(start_date: from.to_date, end_date: to.to_date, metric_id: metric.id)
        curr_count = curr_counts[:tot].to_i
        score_available = enough_data && curr_count >= min_detections
        metric_delta = score_available ? (points.last.to_i - points.first.to_i) : 0

        metric_scores << {
          metric_id: metric.id,
          metric_name: metric.name,
          score: score_available ? points.last.to_i : nil,
          delta: metric_delta,
          delta_abs: metric_delta.abs,
          detections: curr_count,
          ok: score_available,
          reverse: metric.reverse?
        }
      end

      {
        window: window_hash(from, to),
        end_date: to.to_date,
        global_score: overall_points.last.to_i,
        global_delta: overall_points.last.to_i - overall_points.first.to_i,
        global_detections: global_counts[:tot].to_i,
        metrics: metric_scores.sort_by { |m| -(m[:score] || 0) },
        dashboard_aligned: true,
        ok: true
      }
    end

    def self.human_score_error_message(res)
      case res[:reason].to_s
      when "not_enough_data"
        needed = res[:min_required] || 3
        have   = res[:count] || 0
        "Not enough data to compute a score: need at least #{needed} detections, found #{have}."
      when "no_integrations"
        "No connected integrations found for this workspace/user scope."
      when "no_users_in_scope"
        "No users in the selected scope (group/user filter)."
      when "metric_not_found"
        "The specified metric was not found."
      else
        "Unable to compute a score for this window."
      end
    end

    # =========================================================================
    # V2 ENHANCED: metric_score - Returns all metrics when no metric specified
    # =========================================================================
    def self.build_metric_score(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] metric_score args=#{a.inspect} user_id=#{user.id}")

      end_date = a["end_date"].presence || Time.zone.now
      from, to = rolling_30d_window_from_end(end_date)
      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      group_member_ids = integration_user_ids_from_group!(a, user: user)
      return group_member_ids if group_member_ids.is_a?(Hash) && group_member_ids[:error].present?

      # PRIVACY: Only accept group_id - direct integration_user_ids param removed for anonymity protection
      integration_user_ids = group_member_ids

      metric_id = extract_metric_id_from_args(a)

      # If no metric specified, return all metric scores (dashboard-aligned tile math)
      if metric_id.nil?
        workspace_id = a["workspace_id"]
        group_id = a["group_id"].to_i
        group_id = nil if group_id <= 0

        service = DashboardRollupService.new(
          workspace_id: workspace_id,
          logit_margin_min: min_logit,
          group_member_ids: integration_user_ids,
          group_id: group_id
        )

        anchors = dashboard_anchor_days(from.to_date, to.to_date)
        days_analyzed = Integration.joins(:workspace)
                                   .where(workspace_id: workspace_id)
                                   .where(workspaces: { archived_at: nil })
                                   .maximum(:days_analyzed).to_i
        min_detections = Clara::OverviewService::MIN_DETECTIONS
        enough_data = days_analyzed >= 30

        scores = []
        Metric.order(:name).find_each do |metric|
          daily = service.daily_counts(start_date: from.to_date - 29.days, end_date: to.to_date, metric_id: metric.id)
          series = dashboard_rolling30_series(daily, from.to_date, to.to_date, anchors, reverse: metric.reverse?)
          points = series[:points].map(&:round)
          points = [points.first, points.first] if points.size < 2

          curr_counts = service.aggregate_counts(start_date: from.to_date, end_date: to.to_date, metric_id: metric.id)
          curr_count = curr_counts[:tot].to_i
          score_available = enough_data && curr_count >= min_detections
          metric_delta = score_available ? (points.last.to_i - points.first.to_i) : 0

          scores << {
            metric_id: metric.id,
            metric_name: metric.name,
            score: score_available ? points.last.to_i : nil,
            delta: metric_delta,
            delta_abs: metric_delta.abs,
            detections: curr_count,
            ok: score_available,
            reverse: metric.reverse?
          }
        end

        return {
          window: window_hash(from, to),
          end_date: to.to_date,
          dashboard_aligned: true,
          scores: scores.sort_by { |s| -(s[:score] || 0) }
        }
      end

      # Single metric - use dashboard-aligned calculation
      result = dashboard_aligned_score(
        user: user,
        workspace_id: a["workspace_id"],
        start_date: from.to_date,
        end_date: to.to_date,
        metric_id: metric_id,
        integration_user_ids: integration_user_ids,
        group_id: a["group_id"]&.to_i,
        min_logit_margin: min_logit
      )

      metric_name = Metric.where(id: metric_id).pluck(:name).first

      submetrics = Submetric.where(metric_id: metric_id).order(:name).pluck(:id, :name).map do |sid, sname|
        sres = dashboard_aligned_score(
          user: user,
          workspace_id: a["workspace_id"],
          start_date: from.to_date,
          end_date: to.to_date,
          submetric_id: sid,
          integration_user_ids: integration_user_ids,
          group_id: a["group_id"]&.to_i,
          min_logit_margin: min_logit
        )

        {
          submetric_id: sid,
          submetric_name: sname,
          score: sres[:score],
          detections: sres[:detections],
          ok: sres[:ok] != false,
          reason: sres[:ok] != false ? nil : "not_enough_data"
        }
      end

      if !result[:ok]
        return {
          window: window_hash(from, to),
          end_date: to.to_date,
          metric_id: metric_id,
          metric_name: metric_name,
          score: nil,
          detections: result[:detections],
          ok: false,
          reason: "not_enough_data",
          min_required: 3,
          message: human_score_error_message({ reason: "not_enough_data", count: result[:detections], min_required: 3 }),
          submetrics: submetrics
        }
      end

      {
        window: window_hash(from, to),
        end_date: to.to_date,
        metric_id: metric_id,
        metric_name: metric_name,
        score: result[:score],
        detections: result[:detections],
        ok: true,
        dashboard_aligned: true,
        submetrics: submetrics
      }
    end

    # =========================================================================
    # compare_periods - Compare two time periods (using DataQueries)
    # =========================================================================
    def self.build_compare_periods(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] compare_periods args=#{a.inspect} user_id=#{user.id}")

      end_date_a = a["end_date_a"]
      end_date_b = a["end_date_b"]

      return { error: "end_date_a_required" } if end_date_a.blank?
      return { error: "end_date_b_required" } if end_date_b.blank?

      group_member_ids = integration_user_ids_from_group!(a, user: user)
      return group_member_ids if group_member_ids.is_a?(Hash) && group_member_ids[:error].present?

      # PRIVACY: Only accept group_id - direct integration_user_ids param removed for anonymity protection
      integration_user_ids = group_member_ids

      metric_id = extract_metric_id_from_args(a)
      submetric_id = extract_submetric_id_from_args(a)

      from_a, to_a = rolling_30d_window_from_end(end_date_a)
      from_b, to_b = rolling_30d_window_from_end(end_date_b)
      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      result_a = dashboard_aligned_score(
        user: user,
        workspace_id: a["workspace_id"],
        start_date: from_a.to_date,
        end_date: to_a.to_date,
        metric_id: metric_id,
        submetric_id: submetric_id,
        integration_user_ids: integration_user_ids,
        group_id: a["group_id"]&.to_i,
        min_logit_margin: min_logit
      )
      result_b = dashboard_aligned_score(
        user: user,
        workspace_id: a["workspace_id"],
        start_date: from_b.to_date,
        end_date: to_b.to_date,
        metric_id: metric_id,
        submetric_id: submetric_id,
        integration_user_ids: integration_user_ids,
        group_id: a["group_id"]&.to_i,
        min_logit_margin: min_logit
      )

      score_a = result_a[:score]
      score_b = result_b[:score]
      delta = (score_a && score_b) ? (score_b - score_a).round(1) : nil
      direction = delta.nil? ? "unknown" : (delta > 2 ? "up" : (delta < -2 ? "down" : "stable"))

      result = {
        period_a: { window: window_hash(from_a, to_a), score: score_a, detections: result_a[:detections] },
        period_b: { window: window_hash(from_b, to_b), score: score_b, detections: result_b[:detections] },
        delta: delta,
        direction: direction,
        dashboard_aligned: true
      }

      if delta
        direction_word = case direction
          when "up" then "increased"
          when "down" then "decreased"
          else "remained stable"
        end
        result[:summary] = "Score #{direction_word} by #{delta.abs} points (#{score_a&.round(1)} → #{score_b&.round(1)})"
      end

      result
    end

    # =========================================================================
    # compare_groups - Compare across teams/groups (using DataQueries)
    # =========================================================================
    def self.build_compare_groups(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] compare_groups args=#{a.inspect} user_id=#{user.id}")

      group_ids = Array(a["group_ids"]).map(&:to_i).select(&:positive?)
      return { error: "group_ids_required" } if group_ids.empty?

      end_date = a["end_date"].presence || Time.zone.now
      from, to = rolling_30d_window_from_end(end_date)
      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      metric_id = extract_metric_id_from_args(a)
      submetric_id = extract_submetric_id_from_args(a)

      groups_data = []
      group_names = Group.where(id: group_ids).pluck(:id, :name).to_h

      group_ids.each do |gid|
        member_ids = integration_user_ids_for_groups(
          group_ids: [gid],
          group_names: [],
          user: user,
          workspace_id: a["workspace_id"]
        )
        next if member_ids.blank? || member_ids.size < 3

        result = dashboard_aligned_score(
          user: user,
          workspace_id: a["workspace_id"],
          start_date: from.to_date,
          end_date: to.to_date,
          metric_id: metric_id,
          submetric_id: submetric_id,
          integration_user_ids: member_ids,
          group_id: gid,
          min_logit_margin: min_logit
        )

        groups_data << {
          group_id: gid,
          name: group_names[gid] || "Group #{gid}",
          score: result[:score]&.round(1),
          detections: result[:detections],
          member_count: member_ids.size
        }
      end

      # Sort by score descending
      groups_data.sort_by! { |g| -(g[:score] || 0) }

      # Add ranking
      groups_data.each_with_index { |g, i| g[:rank] = i + 1 }

      result = {
        window: window_hash(from, to),
        groups: groups_data,
        dashboard_aligned: true
      }

      if groups_data.size >= 2
        highest = groups_data.first
        lowest = groups_data.last
        if highest[:score] && lowest[:score]
          result[:summary] = "#{highest[:name]} leads with #{highest[:score]}, #{lowest[:name]} trails at #{lowest[:score]}"
        end
      end

      result
    end

    # =========================================================================
    # trend_series - Time series with trend direction (using DataQueries)
    # =========================================================================
    def self.build_trend_series(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] trend_series args=#{a.inspect} user_id=#{user.id}")

      start_date = a["start_date"]
      return { error: "start_date_required" } if start_date.blank?

      end_date = a["end_date"].presence || Time.zone.now
      interval = a["interval"].presence || "weekly"

      group_member_ids = integration_user_ids_from_group!(a, user: user)
      return group_member_ids if group_member_ids.is_a?(Hash) && group_member_ids[:error].present?

      # PRIVACY: Only accept group_id - direct integration_user_ids param removed for anonymity protection
      integration_user_ids = group_member_ids

      metric_id = extract_metric_id_from_args(a)
      submetric_id = extract_submetric_id_from_args(a)

      from = iso!(start_date)
      to = iso!(end_date).end_of_day

      opts = {
        metric_ids: metric_id ? [metric_id] : nil,
        submetric_ids: submetric_id ? [submetric_id] : nil,
        workspace_id: a["workspace_id"],
        integration_user_ids: integration_user_ids
      }.compact

      points = AiChat::DataQueries.timeseries(
        user: user,
        category: nil,
        from: from,
        to: to,
        metric: :pos_rate,
        **opts
      )

      # Resample to weekly if requested
      if interval == "weekly"
        grouped = {}
        points.each do |pt|
          d = pt[:date] || pt["date"]
          dd = d.respond_to?(:to_date) ? d.to_date : (Date.parse(d.to_s) rescue nil)
          next unless dd
          bucket = dd.beginning_of_week
          grouped[bucket] ||= []
          grouped[bucket] << pt
        end
        points = grouped.map do |wk, arr|
          vals = arr.map { |p| p[:value] || p["value"] }.compact
          { date: wk, value: vals.any? ? (vals.sum / vals.size) : nil }
        end.sort_by { |pt| pt[:date] }
      end

      # Calculate trend
      valid_points = points.select { |p| p[:value] }
      trend = "unknown"
      if valid_points.size >= 2
        first_val = valid_points.first[:value]
        last_val = valid_points.last[:value]
        delta = last_val - first_val
        trend = delta > 0.02 ? "improving" : (delta < -0.02 ? "declining" : "stable")
      end

      trend_desc = case trend
        when "improving" then "trending upward"
        when "declining" then "trending downward"
        when "stable" then "holding steady"
        else "insufficient data to determine trend"
      end

      {
        window: window_hash(from, to),
        interval: interval,
        points: points,
        trend: trend,
        trend_description: trend_desc
      }
    end




    def self.build_submetric_score(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] submetric_score args=#{a.inspect} user_id=#{user.id}")

      end_date = a["end_date"].presence || Time.zone.now
      from, to  = rolling_30d_window_from_end(end_date)
      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      group_member_ids = integration_user_ids_from_group!(a, user: user)
      return group_member_ids if group_member_ids.is_a?(Hash) && group_member_ids[:error].present?

      # PRIVACY: Only accept group_id - direct integration_user_ids param removed for anonymity protection
      integration_user_ids = group_member_ids

      submetric_id = extract_submetric_id_from_args(a)

      # If no submetric specified, return all submetric scores
      if submetric_id.nil?
        all_submetrics = Submetric.joins(:metric).order("submetrics.name").pluck(:id, :name, :metric_id)
        metric_names = Metric.pluck(:id, :name).to_h
        scores = []

        all_submetrics.each do |sid, sname, mid|
          result = dashboard_aligned_score(
            user: user,
            workspace_id: a["workspace_id"],
            start_date: from.to_date,
            end_date: to.to_date,
            submetric_id: sid,
            integration_user_ids: integration_user_ids,
            group_id: a["group_id"]&.to_i,
            min_logit_margin: min_logit
          )

          scores << {
            submetric_id: sid,
            submetric_name: sname,
            metric_id: mid,
            metric_name: metric_names[mid],
            score: result[:score],
            detections: result[:detections],
            ok: result[:ok]
          }
        end

        return {
          window: window_hash(from, to),
          end_date: to.to_date,
          scores: scores.sort_by { |s| -(s[:score] || 0) },
          dashboard_aligned: true
        }
      end

      # Single submetric score
      result = dashboard_aligned_score(
        user: user,
        workspace_id: a["workspace_id"],
        start_date: from.to_date,
        end_date: to.to_date,
        submetric_id: submetric_id,
        integration_user_ids: integration_user_ids,
        group_id: a["group_id"]&.to_i,
        min_logit_margin: min_logit
      )

      if !result[:ok]
        return {
          window: window_hash(from, to),
          end_date: to.to_date,
          submetric_id: submetric_id,
          score: nil,
          detections: result[:detections],
          ok: false,
          reason: "not_enough_data",
          min_required: 3,
          message: human_score_error_message({ reason: "not_enough_data", count: result[:detections], min_required: 3 }),
          dashboard_aligned: true
        }
      end

      {
        window: window_hash(from, to),
        end_date: to.to_date,
        submetric_id: submetric_id,
        score: result[:score],
        detections: result[:detections],
        ok: true,
        dashboard_aligned: true
      }
    end


    def self.build_list_metrics(args, user:)
      q = args["query"].to_s.strip.downcase

      scope = Metric.all
      scope = scope.where("LOWER(name) LIKE ?", "%#{q}%") if q.present?

      rows = scope.order(:name).pluck(:id, :name, :reverse).map do |id, name, rev|
        { id: id, name: name, reverse: !!rev }
      end

      { metrics: rows }
    end

    def self.build_list_submetrics(args, user:)
      q = args["query"].to_s.strip.downcase

      metric_id = nil
      if args["metric"].present?
        mid = Integer(args["metric"]) rescue nil
        metric_id = mid if mid.to_i.positive?
        if metric_id.nil?
          name = args["metric"].to_s.strip
          metric_id = metric_ids_for([name]).first
        end
      end

      scope = Submetric.all
      scope = scope.where(metric_id: metric_id) if metric_id.present?
      scope = scope.where("LOWER(name) LIKE ?", "%#{q}%") if q.present?

      metric_names = Metric.pluck(:id, :name).to_h

      rows = scope.order(:name).pluck(:id, :name, :metric_id).map do |id, name, mid|
        { id: id, name: name, metric_id: mid, metric_name: metric_names[mid] }
      end

      { submetrics: rows }
    end



    def self.integration_user_ids_from_group!(args, user:)
      gid = args["group_id"].to_i
      gname = args["group_name"].to_s.strip
      gname = nil if gname.blank?

      return nil if gid <= 0 && gname.nil?

      ws_id = args["workspace_id"]
      member_ids = integration_user_ids_for_groups(
        group_ids: (gid > 0 ? [gid] : []),
        group_names: (gname ? [gname] : []),
        user: user,
        workspace_id: ws_id
      )

      return { error: "group_not_found_or_inaccessible" } if member_ids.blank?
      return { error: "group_too_small", member_count: member_ids.size, min_required: 3 } if member_ids.size < 3

      member_ids
    end



    def self.extract_submetric_id_from_args(args)
      sub = args["submetric"]
      if sub.present?
        sid = Integer(sub) rescue nil
        return sid if sid.to_i.positive?
        name = sub.to_s.strip
        return submetric_ids_for([name]).first if name.present?
      end

      sid = args["submetric_id"].to_i
      return sid if sid.positive?

      name = args["submetric_name"].to_s.strip
      return nil if name.blank?
      submetric_ids_for([name]).first
    end


    def self.build_recommendation_brief(args, user:)
      a = args.deep_dup
      from, to = window_from_args(a)
      limit = a["max_recommendations"].to_i
      limit = 3 if limit <= 0

      metric_ids = metric_ids_from_args(a)
      filters = {
        workspace_id: a["workspace_id"],
        categories: Array(a["categories"]).presence,
        category_ids: Array(a["category_ids"]).presence
      }.compact

      drivers = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: :category,
        metric_ids: metric_ids,
        **filters
      )

      ranked = Array(drivers).sort_by { |row| -((row[:neg_rate] || row["neg_rate"] || 0.0).to_f) }.first(limit)

      recs = ranked.map do |row|
        label = row[:label] || row["label"] || row[:category]
        neg = row[:neg_rate] || row["neg_rate"]
        total = row[:total] || row["total"]
        query = [args["query"], label, "culture guidance"].compact.join(" ")
        doc = guidance_hits_for(query, limit: 1).first
        doc_body = doc && (doc[:body] || doc["body"])
        reference = if doc
          { title: doc[:title] || doc["title"], source_ref: doc[:source_ref] || doc["source_ref"] }
        end

        {
          label: label,
          negative_rate: neg,
          total: total.to_i,
          recommendation: doc_body.presence || "Connect leadership to this topic with targeted comms and follow-ups.",
          reference: reference
        }
      end

      bullets = recs.map do |rec|
        "**#{rec[:label]}** — #{format_percent(rec[:negative_rate])} negative; #{rec[:recommendation].to_s.truncate(120)}"
      end

      blocks = []
      if recs.any?
        blocks << {
          "type" => "callout",
          "title" => "Recommended actions",
          "text" => recs.first[:recommendation]
        }
      end
      blocks << { "type" => "bullets", "title" => "Focus areas", "items" => bullets } if bullets.any?

      {
        window: window_hash(from, to),
        metric_ids: metric_ids,
        recommendations: recs,
        blocks: blocks
      }
    end

    def self.build_insight_plan(args, user:)
      defaults = args["defaults"].is_a?(Hash) ? args["defaults"] : {}
      sections_input = Array(args["sections"])
      return { error: "sections_required" } if sections_input.blank?

      built_sections = []
      aggregate_blocks = []

      sections_input.each do |section|
        next unless section.is_a?(Hash)
        kind = section["kind"].to_s
        next if kind.blank?
        merged_args = defaults.deep_dup rescue defaults.dup
        merged_args ||= {}
        merged_args.merge!(section["args"] || {})

        result = case kind
                 when "kpi"
                   build_topline_kpi_summary(merged_args, user: user)
                 when "trend"
                   build_timeseries_bundle(merged_args, user: user)
                 when "drivers"
                   build_driver_breakdown(merged_args, user: user)
                 when "segments"
                   build_segment_compare(merged_args, user: user)
                 when "event"
                   build_event_window_compare(merged_args, user: user)
                 when "root_cause"
                   build_root_cause_detector(merged_args, user: user)
                 when "recommendations"
                   build_recommendation_brief(merged_args, user: user)
                 when "global_score"
                   build_global_score(merged_args, user: user)
                 when "metric_score"
                   build_metric_score(merged_args, user: user)
                 when "submetric_score"
                   build_submetric_score(merged_args, user: user)
                 else
                   nil
                 end

        next unless result
        built_sections << { kind: kind, data: result }
        aggregate_blocks.concat(Array(result[:blocks])) if result[:blocks].is_a?(Array)
      end

      {
        sections: built_sections,
        blocks: aggregate_blocks
      }
    end

    def self.build_key_takeaways(args, user:)
      summary_args = args.deep_dup rescue args.dup
      summary_args ||= {}
      kpi = build_topline_kpi_summary(summary_args, user: user)
      metrics = Array(kpi[:metrics])

      strongest = metrics.compact.max_by { |m| m[:pos_rate].to_f }
      weakest   = metrics.compact.min_by { |m| m[:pos_rate].to_f }
      biggest_move = metrics.compact.max_by { |m| m[:delta_pos_pp].to_f.abs rescue 0.0 }

      bullets = []
      if strongest
        bullets << "Strongest area: **#{strongest[:metric]}** at #{format_percent(strongest[:pos_rate])} positive."
      end
      if weakest
        bullets << "Biggest risk: **#{weakest[:metric]}** at #{format_percent(weakest[:pos_rate])} positive."
      end
      if biggest_move && biggest_move[:delta_pos_pp]
        dir = biggest_move[:delta_pos_pp] >= 0 ? "improved" : "worsened"
        bullets << "**#{biggest_move[:metric]}** has #{dir} by #{biggest_move[:delta_pos_pp].abs.round(1)} pp vs the comparison window."
      end

      max_bullets = args["max_bullets"].to_i
      max_bullets = 3 if max_bullets <= 0
      bullets = bullets.first(max_bullets)

      blocks = []
      blocks << { "type" => "bullets", "title" => "Key takeaways", "items" => bullets } if bullets.any?
      blocks.concat(Array(kpi[:blocks])) if kpi[:blocks].is_a?(Array)

      {
        window: kpi[:window],
        comparison_window: kpi[:comparison_window],
        metrics: metrics,
        takeaways: bullets,
        blocks: blocks
      }
    end

    def self.extract_metric_id_from_args(args)
      # Accept a unified `metric` field (id or name), plus legacy metric_id/metric_name.
      metric = args["metric"]
      if metric.present?
        metric_id = Integer(metric) rescue nil
        return metric_id if metric_id.to_i.positive?

        name = metric.to_s.strip
        return metric_ids_for([name]).first if name.present?
      end

      metric_id = args["metric_id"].to_i if args["metric_id"].to_i.positive?
      return metric_id if metric_id

      name = args["metric_name"].to_s.strip
      return nil if name.blank?
      metric_ids_for([name]).first
    end

    def self.build_metric_deep_dive(args, user:)
      a = args.deep_dup rescue args.dup
      a ||= {}
      from, to = window_from_args(a, fallback_days: 60)
      metric_id = extract_metric_id_from_args(a)
      return { error: "metric_required" } unless metric_id

      a["metric_ids"] = Array(a["metric_ids"]) + [metric_id]
      kpi = build_topline_kpi_summary(a, user: user)
      metrics = Array(kpi[:metrics])
      target = metrics.find { |m| m[:metric_id] == metric_id } || metrics.first
      return { error: "metric_not_found" } unless target

      submetric_rows = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: :submetric,
        metric_ids: [metric_id],
        workspace_id: a["workspace_id"]
      )

      submetrics = Array(submetric_rows).map do |row|
        {
          name: row[:label] || row["label"],
          total: (row[:total] || row["total"]).to_i,
          pos_rate: row[:pos_rate] || row["pos_rate"],
          neg_rate: row[:neg_rate] || row["neg_rate"]
        }
      end.sort_by { |s| s[:pos_rate].to_f }

      driver_args = a.merge(
        "metric_id" => metric_id,
        "group_by" => "category",
        "top_n" => (a["top_driver_count"].to_i.positive? ? a["top_driver_count"].to_i : 5)
      )
      drivers_result = build_driver_breakdown(driver_args, user: user)

      ranked = metrics.compact.sort_by { |m| m[:pos_rate].to_f }
      rank_index = ranked.index { |m| m[:metric_id] == metric_id }

      context = {
        metrics: metrics,
        rank_position: (rank_index && rank_index + 1),
        total_metrics: ranked.size,
        strongest_metric: ranked.last,
        weakest_metric: ranked.first
      }

      blocks = []
      blocks.concat(Array(kpi[:blocks])) if kpi[:blocks].is_a?(Array)
      blocks.concat(Array(drivers_result[:blocks])) if drivers_result[:blocks].is_a?(Array)

      {
        window: window_hash(from, to),
        metric: target,
        submetrics: submetrics,
        key_drivers: drivers_result[:drivers],
        context: context,
        blocks: blocks
      }
    end

    def self.build_submetric_breakdown(args, user:)
      a = args.deep_dup rescue args.dup
      a ||= {}
      from, to = window_from_args(a, fallback_days: 60)
      metric_id = extract_metric_id_from_args(a)
      return { error: "metric_required" } unless metric_id

      top_n = a["top_signals_per_submetric"].to_i
      top_n = 3 if top_n <= 0

      submetric_rows = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: :submetric,
        metric_ids: [metric_id],
        workspace_id: a["workspace_id"]
      )

      submetrics = []
      Array(submetric_rows).each do |row|
        label = row[:label] || row["label"]
        sub = Submetric.where("LOWER(name)=?", label.to_s.downcase).first

        signals = []
        if sub
          sig_rows = AiChat::DataQueries.window_aggregates(
            user: user,
            from: from,
            to: to,
            group_by: :category,
            submetric_ids: [sub.id],
            workspace_id: a["workspace_id"]
          )
          sorted = Array(sig_rows).sort_by { |r| -((r[:neg_rate] || r["neg_rate"] || 0.0).to_f) }
          signals = sorted.first(top_n).map do |r|
            {
              name: r[:label] || r["label"] || r[:category] || r["category"],
              total: (r[:total] || r["total"]).to_i,
              pos_rate: r[:pos_rate] || r["pos_rate"],
              neg_rate: r[:neg_rate] || r["neg_rate"]
            }
          end
        end

        submetrics << {
          id: sub&.id,
          name: label,
          total: (row[:total] || row["total"]).to_i,
          pos_rate: row[:pos_rate] || row["pos_rate"],
          neg_rate: row[:neg_rate] || row["neg_rate"],
          top_signals: signals
        }
      end

      {
        window: window_hash(from, to),
        metric_id: metric_id,
        submetrics: submetrics.sort_by { |s| s[:pos_rate].to_f }
      }
    end

    def self.build_top_signals(args, user:)
      a = args.deep_dup rescue args.dup
      a ||= {}
      from, to = window_from_args(a, fallback_days: 60)

      scope = (a["scope"] || "metric").to_s
      direction = (a["direction"] || "negative").to_s
      top_n = a["top_n"].to_i
      top_n = 10 if top_n <= 0

      group_by = scope == "subcategory" ? :subcategory : :category

      metric_ids = []
      submetric_ids = []
      subcategory_ids = []

      metric_ids << a["metric_id"].to_i if a["metric_id"].to_i.positive?
      submetric_ids << a["submetric_id"].to_i if a["submetric_id"].to_i.positive?
      subcategory_ids << a["subcategory_id"].to_i if a["subcategory_id"].to_i.positive?

      metric_ids |= metric_ids_for([a["metric_name"]]) if a["metric_name"].present?
      submetric_ids |= submetric_ids_for([a["submetric_name"]]) if a["submetric_name"].present?
      subcategory_ids |= subcategory_ids_for([a["subcategory_name"]]) if a["subcategory_name"].present?

      rows = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: group_by,
        workspace_id: a["workspace_id"],
        metric_ids: metric_ids.presence,
        submetric_ids: submetric_ids.presence,
        subcategory_ids: subcategory_ids.presence
      )

      sorted = Array(rows).sort_by do |r|
        pos = r[:pos_rate] || r["pos_rate"]
        neg = r[:neg_rate] || r["neg_rate"]
        direction == "positive" ? -(pos.to_f) : -(neg.to_f)
      end

      top = sorted.first(top_n)

      signals = top.map do |r|
        label = r[:label] || r["label"] || r[:category] || r["category"]
        desc =
          if group_by == :subcategory
            SignalSubcategory.where("LOWER(name)=?", label.to_s.downcase).limit(1).pluck(:description).first
          else
            SignalCategory.where("LOWER(name)=?", label.to_s.downcase).limit(1).pluck(:description).first
          end

        {
          name: label,
          total: (r[:total] || r["total"]).to_i,
          pos_rate: r[:pos_rate] || r["pos_rate"],
          neg_rate: r[:neg_rate] || r["neg_rate"],
          description: desc
        }
      end

      {
        window: window_hash(from, to),
        scope: scope,
        direction: direction,
        group_by: group_by,
        signals: signals
      }
    end

    def self.build_signal_explain(args, user:)
      metric_name      = args["metric_name"].to_s.strip
      submetric_name   = args["submetric_name"].to_s.strip
      category_name    = args["signal_category"].to_s.strip
      subcategory_name = args["signal_subcategory"].to_s.strip
      query            = args["query"].to_s.strip

      info = nil

      if category_name.present?
        cat = SignalCategory.where("LOWER(name)=?", category_name.downcase).first
        if cat
          info = {
            kind: "signal_category",
            name: cat.name,
            description: cat.description,
            positive_threshold: cat.positive_threshold,
            negative_threshold: cat.negative_threshold
          }
        end
      elsif subcategory_name.present?
        sub = SignalSubcategory.where("LOWER(name)=?", subcategory_name.downcase).first
        if sub
          info = {
            kind: "signal_subcategory",
            name: sub.name,
            description: sub.description
          }
        end
      elsif submetric_name.present?
        sm = Submetric.where("LOWER(name)=?", submetric_name.downcase).first
        if sm
          info = {
            kind: "submetric",
            name: sm.name,
            description: sm.description
          }
        end
      elsif metric_name.present?
        mt = Metric.where("LOWER(name)=?", metric_name.downcase).first
        if mt
          info = {
            kind: "metric",
            name: mt.name,
            description: mt.description,
            reverse: !!mt.reverse
          }
        end
      end

      hits = []
      if defined?(AiChat::KnowledgeSearch)
        q = query.presence || [metric_name, submetric_name, category_name, subcategory_name].find(&:present?)
        if q.present?
          hits = AiChat::KnowledgeSearch.search(query: q, kinds: %w[metric submetric signal_category signal_subcategory])
        end
      end

      {
        info: info,
        references: Array(hits).map { |h| h.slice(:title, :body, :namespace, :source_ref, :meta) }
      }
    end

    def self.build_stats_analysis(args, user:)
      series_input = Array(args["series"])
      results = []

      series_input.each do |s|
        points = Array(s["points"]).map do |pt|
          next unless pt.is_a?(Hash)
          date = pt["date"] || pt[:date]
          value = pt["value"] || pt[:value]
          next if date.blank? || value.nil?
          { date: date.to_s, value: value.to_f }
        end.compact

        next if points.size < 2

        values = points.map { |p| p[:value] }
        n = values.size
        start_val = values.first
        end_val   = values.last
        delta     = end_val - start_val
        mean      = values.sum / n.to_f
        variance  = values.map { |v| (v - mean) ** 2 }.sum / n.to_f
        stddev    = Math.sqrt(variance)

        direction =
          if delta > (stddev * 0.5)
            "up"
          elsif delta < -(stddev * 0.5)
            "down"
          else
            "flat"
          end

        inflections = []
        (1...(points.size - 1)).each do |i|
          prev = points[i - 1][:value]
          curr = points[i][:value]
          nxt  = points[i + 1][:value]
          next if prev.nil? || curr.nil? || nxt.nil?
          left_slope  = curr - prev
          right_slope = nxt - curr
          if left_slope * right_slope < 0
            inflections << points[i]
          end
        end

        results << {
          label: s["label"] || s[:label],
          metric: s["metric"] || s[:metric],
          start_value: start_val,
          end_value: end_val,
          delta: delta,
          direction: direction,
          mean: mean,
          stddev: stddev,
          inflection_points: inflections
        }
      end

      { series: results }
    end

    def self.build_top_group_signals(args, user:)
      a = args.deep_dup rescue args.dup
      a ||= {}
      from, to = window_from_args(a, fallback_days: 30)

      metric_ids = metric_ids_from_args(a, fallback_limit: 1)
      segments_input = Array(a["segments"])
      return { error: "segments_required" } if segments_input.blank?

      top_n = a["top_n_groups"].to_i
      top_n = 5 if top_n <= 0

      segments = []
      segments_input.each_with_index do |seg, idx|
        next unless seg.is_a?(Hash)
        label = seg["label"].presence || "Group #{idx + 1}"

        group_ids   = Array(seg["group_ids"])
        group_names = Array(seg["group_names"].presence || [label])
        member_ids  = integration_user_ids_for_groups(group_ids: group_ids, group_names: group_names, user: user, workspace_id: a["workspace_id"])
        next if member_ids.blank?

        rows = AiChat::DataQueries.window_aggregates(
          user: user,
          from: from,
          to: to,
          group_by: :category,
          workspace_id: a["workspace_id"],
          metric_ids: metric_ids,
          integration_user_ids: member_ids
        )

        sorted = Array(rows).sort_by { |r| -((r[:neg_rate] || r["neg_rate"] || 0.0).to_f) }
        top = sorted.first(top_n).map do |r|
          {
            name: r[:label] || r["label"] || r[:category] || r["category"],
            total: (r[:total] || r["total"]).to_i,
            pos_rate: r[:pos_rate] || r["pos_rate"],
            neg_rate: r[:neg_rate] || r["neg_rate"]
          }
        end

        segments << {
          label: label,
          integration_user_ids: member_ids,
          workspace_user_ids: member_ids, # legacy alias
          top_signals: top
        }
      end

      { window: window_hash(from, to), metric_ids: metric_ids, segments: segments }
    end

    def self.build_segment_trend(args, user:)
      a = args.deep_dup rescue args.dup
      a ||= {}
      from, to = window_from_args(a, fallback_days: 60)
      metric_ids = metric_ids_from_args(a, fallback_limit: 1)
      metric_kind = :pos_rate

      segments_input = Array(a["segments"])
      return { error: "segments_required" } if segments_input.size < 2

      cadence = (a["cadence"] || "day").to_s

      segments = []
      segments_input.each_with_index do |seg, idx|
        next unless seg.is_a?(Hash)
        label = seg["label"].presence || "Group #{idx + 1}"

        group_ids   = Array(seg["group_ids"])
        group_names = Array(seg["group_names"].presence || [label])
        member_ids  = integration_user_ids_for_groups(group_ids: group_ids, group_names: group_names, user: user, workspace_id: a["workspace_id"])
        next if member_ids.blank?

        ts = series_from_timeseries(
          user: user,
          filters: { workspace_id: a["workspace_id"], integration_user_ids: member_ids },
          spec: { metric_ids: metric_ids, submetric_ids: [], subcategory_ids: [], category: nil },
          from: from,
          to: to,
          metric_kind: metric_kind,
          cadence: cadence
        )

        segments << {
          label: label,
          integration_user_ids: member_ids,
          workspace_user_ids: member_ids,
          points: ts[:points]
        }
      end

      { window: window_hash(from, to), metric_ids: metric_ids, segments: segments, cadence: cadence }
    end

    def self.build_group_trends(args, user:)
      a = args.deep_dup rescue args.dup
      a ||= {}

      from, to = window_from_args(a, fallback_days: 30)
      metric_ids  = metric_ids_from_args(a, fallback_limit: 1)
      metric_info = metric_info_for(metric_ids)
      metric_kind = (a["metric"] || a["metric_kind"] || "pos_rate").to_sym
      cadence     = (a["cadence"] || "week").to_s
      top_n       = a["top_n"].to_i
      top_n       = 5 if top_n <= 0

      ws_ids = accessible_workspace_ids(user: user, workspace_id: a["workspace_id"])
      return { window: window_hash(from, to), metric_ids: metric_ids, metric_info: metric_info, groups: [] } if ws_ids.empty?

      group_ids   = Array(a["group_ids"]).map(&:to_i).reject(&:zero?)
      group_names = Array(a["group_names"]).map { |n| n.to_s.strip.downcase }.reject(&:blank?)

      scope = Group.where(workspace_id: ws_ids)
      scope = scope.where(id: group_ids) if group_ids.any?
      if group_names.any?
        scope = scope.where("LOWER(name) IN (?)", group_names) if group_ids.empty?
      end

      groups = scope.order(:name).limit(50).to_a
      results = []

      groups.each do |g|
        member_ids = integration_user_ids_for_groups(
          group_ids: [g.id],
          group_names: [],
          user: user,
          workspace_id: a["workspace_id"]
        )
        next if member_ids.blank?

        ts = series_from_timeseries(
          user: user,
          filters: { workspace_id: a["workspace_id"], integration_user_ids: member_ids },
          spec: { metric_ids: metric_ids, submetric_ids: [], subcategory_ids: [], category: nil },
          from: from,
          to: to,
          metric_kind: metric_kind,
          cadence: cadence
        )

        points = Array(ts[:points])
        next if points.empty?

        start_pt = points.find { |pt| !pt[:value].nil? }
        end_pt   = points.reverse.find { |pt| !pt[:value].nil? }
        start_val = start_pt&.dig(:value)
        end_val   = end_pt&.dig(:value)

        change_val = if start_val && end_val
          delta = end_val.to_f - start_val.to_f
          metric_kind == :total ? delta.round(0) : (delta * 100.0).round(1)
        end

        results << {
          group_id: g.id,
          group_name: g.name,
          member_count: member_ids.size,
          start_value: start_val,
          end_value: end_val,
          change: change_val,
          trend: delta_label(change_val),
          cadence: cadence,
          points: points
        }
      end

      sorted = results.sort_by { |r| r[:change].nil? ? 0 : r[:change].to_f }

      {
        window: window_hash(from, to),
        metric: metric_kind_label(metric_kind),
        metric_ids: metric_ids,
        metric_info: metric_info,
        cadence: cadence,
        groups: sorted,
        worst: sorted.first(top_n),
        best: sorted.reverse.first(top_n)
      }
    end

    def self.build_multi_event_analysis(args, user:)
      events = Array(args["events"])
      return { error: "events_required" } if events.blank?

      metric_names = Array(args["metrics"])
      metric_ids   = Array(args["metric_ids"])

      results = []
      events.each do |evt|
        next unless evt.is_a?(Hash)
        date = evt["date"] || evt[:date]
        next if date.blank?

        local_args = {
          "event_date" => date,
          "pre_days"   => evt["pre_days"] || evt[:pre_days],
          "post_days"  => evt["post_days"] || evt[:post_days],
          "metric_names" => metric_names,
          "metric_ids"   => metric_ids
        }

        data = build_event_window_compare(local_args, user: user)
        results << {
          label: evt["label"] || evt[:label] || date.to_s,
          event_date: data[:event_date],
          before_window: data[:before_window],
          after_window: data[:after_window],
          comparison: data[:comparison]
        }
      end

      { events: results }
    end

    def self.build_keyword_filter(args, user:)
      {
        error: "keyword_filter_not_supported",
        message: "Keyword-based slicing of detections by references is not yet implemented in this environment."
      }
    end

    def self.build_correlation_analysis(args, user:)
      a = args.deep_dup rescue args.dup
      a ||= {}
      from, to = window_from_args(a, fallback_days: 90)

      metric_ids = Array(a["metric_ids"]).map(&:to_i).reject(&:zero?)
      if metric_ids.blank?
        names = Array(a["metric_names"]).map { |n| n.to_s.strip }.reject(&:blank?)
        metric_ids = metric_ids_for(names)
      end
      metric_ids = metric_ids.uniq
      return { error: "metrics_required" } if metric_ids.size < 2

      metric_info = metric_info_for(metric_ids)

      filters = {
        workspace_id: a["workspace_id"],
        categories: Array(a["categories"]).presence,
        category_ids: Array(a["category_ids"]).presence,
        submetric_ids: Array(a["submetric_ids"]).presence,
        subcategory_ids: Array(a["subcategory_ids"]).presence
      }.compact

      metric_kind = :pos_rate
      cadence = (a["cadence"] || "day").to_s

      series = {}
      metric_ids.each do |mid|
        pts = AiChat::DataQueries.timeseries(
          user: user,
          category: nil,
          from: from,
          to: to,
          metric: metric_kind,
          metric_ids: [mid],
          workspace_id: filters[:workspace_id],
          submetric_ids: filters[:submetric_ids],
          subcategory_ids: filters[:subcategory_ids]
        )

        points = if cadence == "week"
          grouped = {}
          pts.each do |pt|
            d = pt[:date] || pt["date"]
            dd = d.respond_to?(:to_date) ? d.to_date : (Date.parse(d.to_s) rescue nil)
            next unless dd
            bucket = dd.beginning_of_week
            grouped[bucket] ||= []
            grouped[bucket] << pt
          end
          grouped.map do |wk, arr|
            vals = arr.map { |p| p[:value] || p["value"] }.compact
            { date: wk, value: vals.any? ? (vals.sum / vals.size) : nil }
          end.sort_by { |pt| pt[:date] }
        else
          pts
        end

        series[mid] = points
      end

      correlations = []
      metric_ids.combination(2).each do |a_id, b_id|
        a_points = Array(series[a_id])
        b_points = Array(series[b_id])
        next if a_points.empty? || b_points.empty?

        vals_a = a_points.map { |p| p[:value] || p["value"] }
        vals_b = b_points.map { |p| p[:value] || p["value"] }
        paired = vals_a.zip(vals_b).reject { |x, y| x.nil? || y.nil? }
        next if paired.size < 3

        xs = paired.map(&:first).map(&:to_f)
        ys = paired.map(&:last).map(&:to_f)
        corr = pearson_correlation(xs, ys)

        correlations << {
          metric_a_id: a_id,
          metric_a: metric_info[a_id]&.dig(:name) || "Metric #{a_id}",
          metric_b_id: b_id,
          metric_b: metric_info[b_id]&.dig(:name) || "Metric #{b_id}",
          correlation: corr
        }
      end

      {
        window: window_hash(from, to),
        metric_ids: metric_ids,
        correlations: correlations,
        series: series.transform_keys { |mid| metric_info[mid]&.dig(:name) || "Metric #{mid}" }
      }
    end

    def self.build_misalignment_detector(args, user:)
      a = args.deep_dup rescue args.dup
      a ||= {}
      from, to = window_from_args(a, fallback_days: 60)

      metric_ids = metric_ids_from_args(a)
      leader_seg = a["leader_segment"] || {}
      ic_seg     = a["ic_segment"] || {}

      leader_members = integration_user_ids_for_groups(
        group_ids:   leader_seg["group_ids"],
        group_names: Array(leader_seg["group_names"].presence || [leader_seg["label"] || "Leaders"]),
        user: user,
        workspace_id: a["workspace_id"]
      )
      ic_members = integration_user_ids_for_groups(
        group_ids:   ic_seg["group_ids"],
        group_names: Array(ic_seg["group_names"].presence || [ic_seg["label"] || "ICs"]),
        user: user,
        workspace_id: a["workspace_id"]
      )

      return { error: "segments_not_computed" } if leader_members.blank? || ic_members.blank?

      common_filters = {
        workspace_id: a["workspace_id"],
        categories: Array(a["categories"]).presence,
        category_ids: Array(a["category_ids"]).presence,
        submetric_ids: Array(a["submetric_ids"]).presence,
        subcategory_ids: Array(a["subcategory_ids"]).presence
      }.compact

      leader_rows = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: :metric,
        metric_ids: metric_ids,
        integration_user_ids: leader_members,
        **common_filters
      )

      ic_rows = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: :metric,
        metric_ids: metric_ids,
        integration_user_ids: ic_members,
        **common_filters
      )

      leader_stat = leader_rows.first
      ic_stat     = ic_rows.first
      return { error: "segments_not_computed" } unless leader_stat && ic_stat

      leader_pos = leader_stat[:pos_rate] || leader_stat["pos_rate"]
      ic_pos     = ic_stat[:pos_rate] || ic_stat["pos_rate"]
      gap_pp     = ((leader_pos.to_f - ic_pos.to_f) * 100.0).round(1)

      {
        window: window_hash(from, to),
        metric_ids: metric_ids,
        leader_segment: {
          label: leader_seg["label"].presence || "Leaders",
          integration_user_ids: leader_members,
          workspace_user_ids: leader_members,
          total: leader_stat[:total] || leader_stat["total"],
          pos_rate: leader_pos,
          neg_rate: leader_stat[:neg_rate] || leader_stat["neg_rate"]
        },
        ic_segment: {
          label: ic_seg["label"].presence || "ICs",
          integration_user_ids: ic_members,
          workspace_user_ids: ic_members,
          total: ic_stat[:total] || ic_stat["total"],
          pos_rate: ic_pos,
          neg_rate: ic_stat[:neg_rate] || ic_stat["neg_rate"]
        },
        gap_positive_pp: gap_pp
      }
    end

    def self.build_benchmark_comparison(args, user:)
      metric_names = Array(args["metric_names"])
      metric_ids   = Array(args["metric_ids"])
      {
        metric_names: metric_names,
        metric_ids: metric_ids,
        benchmark_set: args["benchmark_set"],
        error: "benchmarks_not_configured",
        message: "External or industry benchmark data is not configured for this environment. You can still compare trends over time and between segments using the other tools."
      }
    end

    def self.safe_delta(a, b)
      return nil if a.nil? || b.nil?
      (a.to_f - b.to_f).round(6)
    end

    def self.pearson_correlation(xs, ys)
      xs = Array(xs).map(&:to_f)
      ys = Array(ys).map(&:to_f)
      n = [xs.size, ys.size].min
      return nil if n <= 1

      mean_x = xs.sum / n.to_f
      mean_y = ys.sum / n.to_f

      num = 0.0
      den_x = 0.0
      den_y = 0.0

      n.times do |i|
        dx = xs[i] - mean_x
        dy = ys[i] - mean_y
        num  += dx * dy
        den_x += dx * dx
        den_y += dy * dy
      end

      return nil if den_x.zero? || den_y.zero?
      (num / Math.sqrt(den_x * den_y)).round(3)
    end

    # Resolve ids by LOWER(name)
    def self.ids_for(klass, names)
      ary = Array(names).map { |x| x.to_s.strip.downcase }.reject(&:blank?)
      return [] if ary.empty?
      klass.where("LOWER(name) IN (?)", ary).pluck(:id)
    end

    def self.metric_ids_for(names)
      ids_for(Metric, names)
    end

    def self.submetric_ids_for(names)
      ids_for(Submetric, names)
    end

    def self.subcategory_ids_for(names)
      ids_for(SignalSubcategory, names)
    end

    def self.category_ids_for(names)
      ids_for(SignalCategory, names)
    end

    def self.accessible_integration_ids(user:, workspace_id: nil)
      AiChat::DataQueries.integration_ids_for_user(user: user, workspace_id: workspace_id)
    end

    def self.accessible_workspace_ids(user:, workspace_id: nil)
      ids = accessible_integration_ids(user: user, workspace_id: workspace_id)
      return [] if ids.empty?
      Integration.joins(:workspace)
                 .where(id: ids)
                 .where(workspaces: { archived_at: nil })
                 .distinct
                 .pluck(:workspace_id)
    end

    def self.integration_user_ids_for_groups(group_ids:, group_names:, user:, workspace_id: nil)
      integration_ids = accessible_integration_ids(user: user, workspace_id: workspace_id)
      return [] if integration_ids.empty?

      workspace_ids = Integration.joins(:workspace)
                                 .where(id: integration_ids)
                                 .where(workspaces: { archived_at: nil })
                                 .distinct
                                 .pluck(:workspace_id)
      return [] if workspace_ids.empty?

      ids = Array(group_ids).map(&:to_i).reject(&:zero?)
      names = Array(group_names).map { |n| n.to_s.strip.downcase }.reject(&:blank?)

      scope = Group.where(workspace_id: workspace_ids)
      scope = scope.where(id: ids) if ids.any?
      if names.any?
        scope = scope.where("LOWER(name) IN (?)", names) if ids.empty?
      end

      groups = scope.to_a
      return [] if groups.empty?

      GroupMember.joins(:integration_user)
                 .where(group_id: groups.map(&:id), integration_users: { integration_id: integration_ids })
                 .pluck(:integration_user_id)
                 .uniq
    end

    # Make a human label for a series
    def self.series_label_for(args, metric_ids:, submetric_ids:, subcategory_ids:)
      return args["category"].to_s if args["category"].present?

      if Array(metric_ids).size == 1
        return Metric.where(id: metric_ids.first).limit(1).pluck(:name).first
      end
      if Array(submetric_ids).size == 1
        return Submetric.where(id: submetric_ids.first).limit(1).pluck(:name).first
      end
      if Array(subcategory_ids).size == 1
        return SignalSubcategory.where(id: subcategory_ids.first).limit(1).pluck(:name).first
      end

      "Series"
    end

    def self.metric_kind_label(kind)
      case kind.to_sym
      when :total     then "TOTAL"
      when :pos_rate  then "POS_RATE"
      when :neg_rate  then "NEG_RATE"
      when :avg_logit then "AVG_LOGIT"
      else kind.to_s.upcase
      end
    end

    def self.downcase_label(value)
      value.to_s.strip.downcase
    end

    def self.window_hash(from, to)
      { from: from&.to_date, to: to&.to_date }
    end

    def self.format_percent(value)
      return "—" if value.nil?
      "#{(value.to_f * 100.0).round(1)}%"
    end

    def self.delta_label(delta)
      return nil if delta.nil?
      if delta > 0.5
        "rising"
      elsif delta < -0.5
        "falling"
      else
        "steady"
      end
    end

    def self.metric_info_for(ids)
      ids = Array(ids).map(&:to_i).reject(&:zero?).uniq
      return {} if ids.empty?
      Metric.where(id: ids).pluck(:id, :name, :reverse).each_with_object({}) do |(id, name, rev), h|
        h[id] = { id: id, name: name, reverse: !!rev }
      end
    end

    def self.find_by_label(rows, label)
      key = downcase_label(label)
      Array(rows).find do |r|
        val = r[:label] || r["label"] || r[:category] || r["category"]
        downcase_label(val) == key
      end
    end

    def self.metric_ids_from_args(args, fallback_limit: DEFAULT_TOPLINE_METRIC_LIMIT)
      ids = Array(args["metric_ids"]).map(&:to_i).reject(&:zero?)
      names = Array(args["metric_names"]).map { |n| n.to_s.strip }.reject(&:blank?)
      ids += metric_ids_for(names)
      ids = ids.uniq

      if ids.blank?
        limit = fallback_limit.to_i.positive? ? fallback_limit.to_i : DEFAULT_TOPLINE_METRIC_LIMIT
        ids = Metric.order(:id).limit(limit).pluck(:id)
      end

      ids
    end

    def self.window_from_args(args, fallback_days: 30)
      base_now = Time.zone ? Time.zone.now : Time.now
      from = args["start_date"].present? ? iso!(args["start_date"]) : (base_now - fallback_days.to_i.days)
      to   = args["end_date"].present? ? iso!(args["end_date"]).end_of_day : base_now.end_of_day
      [from, to]
    end

    def self.comparison_window_for(args, from, to)
      args ||= {}
      window_days = [(to.to_date - from.to_date).to_i + 1, 1].max
      custom_days = args["comparison_window_days"].to_i
      span_days   = custom_days.positive? ? custom_days : window_days

      if args["comparison_start_date"].present? || args["comparison_end_date"].present?
        comp_from = iso!(args["comparison_start_date"] || (from - span_days.days))
        comp_to   = iso!(args["comparison_end_date"] || (comp_from + span_days.days)).end_of_day
      else
        comp_to   = (from - 1.second)
        comp_from = comp_to - span_days.days + 1.second
      end

      { from: comp_from, to: comp_to }
    rescue
      nil
    end

    def self.series_from_timeseries(user:, filters:, spec:, from:, to:, metric_kind:, cadence: "day")
      params = {
        category:        spec[:category],
        metric_ids:      spec[:metric_ids],
        submetric_ids:   spec[:submetric_ids],
        subcategory_ids: spec[:subcategory_ids],
        metric:          metric_kind,
        start_date:      from.to_date,
        end_date:        to.to_date
      }

      integration_user_ids = filters[:integration_user_ids] || filters[:workspace_user_ids]

      points = AiChat::DataQueries.timeseries(
        user: user,
        category: spec[:category],
        from: from,
        to: to,
        metric: metric_kind,
        metric_ids: spec[:metric_ids],
        submetric_ids: spec[:submetric_ids],
        subcategory_ids: spec[:subcategory_ids],
        workspace_id: filters[:workspace_id],
        integration_user_ids: integration_user_ids
      )

      resampled =
        case cadence.to_s
        when "week"
          grouped = {}
          points.each do |pt|
            d = pt[:date] || pt["date"]
            dd = d.respond_to?(:to_date) ? d.to_date : (Date.parse(d.to_s) rescue nil)
            next unless dd
            bucket = dd.beginning_of_week
            grouped[bucket] ||= []
            grouped[bucket] << pt
          end

          grouped.map do |wk, arr|
            vals = arr.map { |p| p[:value] || p["value"] }.compact
            { date: wk, value: vals.any? ? (vals.sum / vals.size) : nil }
          end.sort_by { |pt| pt[:date] }
        else
          points
        end

      { params: params, points: resampled }
    end

    def self.bundle_series_specs(args, fallback_limit: MAX_SERIES_FOR_BUNDLE)
      specs = []
      Array(args["series"]).each do |entry|
        next unless entry.is_a?(Hash)
        spec = {
          label: entry["label"],
          metric_ids: [],
          submetric_ids: [],
          subcategory_ids: []
        }

        # Prefer explicit positive IDs from the tool; if the model
        # sends 0 or an invalid id, fall back to resolving by name.
        metric_id = (Integer(entry["metric_id"]) rescue nil)
        if metric_id && metric_id > 0
          spec[:metric_ids] << metric_id
        elsif entry["metric_name"].present?
          spec[:metric_ids] += metric_ids_for(entry["metric_name"])
        end

        submetric_id = (Integer(entry["submetric_id"]) rescue nil)
        if submetric_id && submetric_id > 0
          spec[:submetric_ids] << submetric_id
        elsif entry["submetric_name"].present?
          spec[:submetric_ids] += submetric_ids_for(entry["submetric_name"])
        end

        subcategory_id = (Integer(entry["subcategory_id"]) rescue nil)
        if subcategory_id && subcategory_id > 0
          spec[:subcategory_ids] << subcategory_id
        elsif entry["subcategory_name"].present?
          spec[:subcategory_ids] += subcategory_ids_for(entry["subcategory_name"])
        end

        spec[:category] = entry["category"] if entry["category"].present?
        next if spec[:metric_ids].blank? && spec[:submetric_ids].blank? && spec[:subcategory_ids].blank? && spec[:category].blank?

        specs << spec
      end

      return specs if specs.any?

      metric_ids = metric_ids_from_args(args, fallback_limit: fallback_limit)
      info = metric_info_for(metric_ids)
      metric_ids.map do |mid|
        {
          metric_ids: [mid],
          label: info[mid]&.dig(:name) || "Metric #{mid}",
          submetric_ids: [],
          subcategory_ids: []
        }
      end
    end

    def self.guidance_hits_for(query, limit: 3)
      return [] unless defined?(AiChat::KnowledgeSearch)
      q = query.to_s.strip
      return [] if q.blank?
      AiChat::KnowledgeSearch.search(query: q, kinds: %w[metric signal_category]).first(limit)
    rescue
      []
    end

    def self.build_topline_kpi_summary(args, user:)
      a = args.deep_dup
      from, to = window_from_args(a)
      metric_ids = metric_ids_from_args(a)
      metric_info = metric_info_for(metric_ids)
      filters = {
        workspace_id: a["workspace_id"],
        categories: Array(a["categories"]).presence,
        category_ids: Array(a["category_ids"]).presence,
        submetric_names: Array(a["submetric_names"]).presence,
        submetric_ids: Array(a["submetric_ids"]).presence,
        subcategory_names: Array(a["subcategory_names"]).presence,
        subcategory_ids: Array(a["subcategory_ids"]).presence
      }.compact

      current = AiChat::DataQueries.window_aggregates(
        user: user,
        from: from,
        to: to,
        group_by: :metric,
        metric_ids: metric_ids,
        **filters
      )

      comparison_window = comparison_window_for(a, from, to)
      baseline = if comparison_window
        AiChat::DataQueries.window_aggregates(
          user: user,
          from: comparison_window[:from],
          to: comparison_window[:to],
          group_by: :metric,
          metric_ids: metric_ids,
          **filters
        )
      else
        []
      end

      baseline_map = {}
      Array(baseline).each do |row|
        key = downcase_label(row[:label] || row["label"])
        baseline_map[key] = row
      end

      metrics = []
      table_rows = []
      kpi_cards = []

      metric_ids.each do |mid|
        info = metric_info[mid] || {}
        label = info[:name] || "Metric #{mid}"
        curr = find_by_label(current, label) || {}
        base = baseline_map[downcase_label(label)] || {}

        total = curr[:total] || curr["total"] || 0
        pos_rate = curr[:pos_rate] || curr["pos_rate"]
        neg_rate = curr[:neg_rate] || curr["neg_rate"]
        base_pos = base[:pos_rate] || base["pos_rate"]
        delta_pp = if pos_rate.nil? || base_pos.nil?
          nil
        else
          ((pos_rate.to_f - base_pos.to_f) * 100.0).round(1)
        end

        metrics << {
          metric_id: mid,
          metric: label,
          total: total.to_i,
          pos_rate: pos_rate,
          neg_rate: neg_rate,
          delta_pos_pp: delta_pp,
          trend: delta_label(delta_pp)
        }

        sub_text = if delta_pp
          delta_pp >= 0 ? "▲ #{delta_pp} pp vs prior" : "▼ #{delta_pp.abs} pp vs prior"
        else
          "#{total.to_i} signals"
        end

        kpi_cards << {
          "label" => label,
          "value" => format_percent(pos_rate),
          "sub"   => sub_text
        }

        table_rows << [
          label,
          total.to_i,
          format_percent(pos_rate),
          format_percent(neg_rate),
          (delta_pp ? format("%+.1f pp", delta_pp) : "—")
        ]
      end

      blocks = []
      if kpi_cards.any?
        blocks << { "type" => "kpis", "title" => "Culture KPIs (#{from.to_date} → #{to.to_date})", "items" => kpi_cards }
      end

      if table_rows.any?
        blocks << {
          "type" => "table",
          "title" => "Metric summary",
          "columns" => ["Metric","Signals","Positive %","Negative %","Δ Positive"],
          "rows" => table_rows
        }
      end

      {
        window: window_hash(from, to),
        comparison_window: (comparison_window ? window_hash(comparison_window[:from], comparison_window[:to]) : nil),
        metrics: metrics,
        blocks: blocks
      }
    end

    # -------- facet normalizers --------
    # If the model sends categories:["alignment","conflict"] but those are metrics in your schema,
    # this will map them into metric_names and set a sensible group_by.
    def self.normalize_facets_and_group!(args)
      args = args.dup
      names = Array(args["categories"]).map { |x| x.to_s.strip.downcase }.reject(&:blank?)
      return args if names.empty?

      metric_name_set      = Metric.where("LOWER(name) IN (?)", names).pluck(Arel.sql("LOWER(name)")).to_set
      submetric_name_set   = Submetric.where("LOWER(name) IN (?)", names).pluck(Arel.sql("LOWER(name)")).to_set
      subcategory_name_set = SignalSubcategory.where("LOWER(name) IN (?)", names).pluck(Arel.sql("LOWER(name)")).to_set
      category_name_set    = SignalCategory.where("LOWER(name) IN (?)", names).pluck(Arel.sql("LOWER(name)")).to_set

      metric_names      = names.select { |n| metric_name_set.include?(n) }
      submetric_names   = names.select { |n| submetric_name_set.include?(n) }
      subcategory_names = names.select { |n| subcategory_name_set.include?(n) }
      category_names    = names.select { |n| category_name_set.include?(n) }

      # If everything maps to metrics, prefer metrics and group_by: :metric
      if metric_names.any? && category_names.empty? && submetric_names.empty? && subcategory_names.empty?
        args["metric_names"] = (Array(args["metric_names"]) + metric_names).uniq
        args["categories"]   = []
        args["group_by"]   ||= "metric"
        return args
      end

      # Otherwise, split across facets; leave true categories in place
      args["metric_names"]       = (Array(args["metric_names"]) + metric_names).uniq if metric_names.any?
      args["submetric_names"]    = (Array(args["submetric_names"]) + submetric_names).uniq if submetric_names.any?
      args["subcategory_names"]  = (Array(args["subcategory_names"]) + subcategory_names).uniq if subcategory_names.any?
      args["categories"]         = category_names if category_names.any?
      args.delete("categories") if category_names.empty?

      args["group_by"] ||= if metric_names.any?
                              "metric"
                            elsif submetric_names.any?
                              "submetric"
                            elsif subcategory_names.any?
                              "subcategory"
                            else
                              args["group_by"]
                            end
      args
    end

    # If timeseries gets category:"alignment" but that's a metric name, coerce into metric_names, etc.
    def self.normalize_timeseries_facet!(args)
      args = args.dup
      name = args["category"].to_s.strip.downcase
      return args if name.blank?

      if Metric.where("LOWER(name)=?", name).exists?
        args.delete("category")
        args["metric_names"] = Array(args["metric_names"]) + [name]
      elsif Submetric.where("LOWER(name)=?", name).exists?
        args.delete("category")
        args["submetric_names"] = Array(args["submetric_names"]) + [name]
      elsif SignalSubcategory.where("LOWER(name)=?", name).exists?
        args.delete("category")
        args["subcategory_names"] = Array(args["subcategory_names"]) + [name]
      end
      args
    end

    # Static catalog of widget capabilities for the model.
    def self.available_widgets
      [
        {
          name: "sparkline",
          description: "Full-size sparkline chart with axes for a single metric over a date range.",
          params: {
            "metric"       => "Metric name (for example \"Burnout\").",
            "start_date"   => "Start date (YYYY-MM-DD).",
            "end_date"     => "End date (YYYY-MM-DD).",
            "metric_kind"  => "Metric kind: pos_rate | neg_rate | avg_logit | total (optional, default pos_rate)."
          }
        },
        {
          name: "sparkline_chart",
          description: "Compact inline sparkline without axes, useful inside paragraphs.",
          params: {
            "metric"       => "Metric name (for example \"Psychological Safety\").",
            "start_date"   => "Start date (YYYY-MM-DD).",
            "end_date"     => "End date (YYYY-MM-DD).",
            "metric_kind"  => "Metric kind: pos_rate | neg_rate | avg_logit | total (optional, default pos_rate)."
          }
        },
        {
          name: "metric_gauge",
          description: "Single KPI gauge showing a metric value and optional change vs a comparison window.",
          params: {
            "metric" => "Short label for the metric (for example \"Burnout\").",
            "value"  => "Numeric value, either 0–100 or 0–1 (interpreted as positive rate).",
            "change" => "Optional change vs comparison in percentage points (for example -6.2)."
          }
        },
        {
          name: "aggregate_gauge",
          description: "Gauge summarizing a metric over a window, with optional comparison to a previous window.",
          params: {
            "metric"                => "Metric name (for example \"Alignment\").",
            "start_date"            => "Start date (YYYY-MM-DD).",
            "end_date"              => "End date (YYYY-MM-DD).",
            "comparison_start_date" => "Optional comparison start date; if omitted, uses previous same-length window.",
            "comparison_end_date"   => "Optional comparison end date.",
            "notch1"                => "Optional lower threshold (default 25).",
            "notch2"                => "Optional upper threshold (default 75).",
            "reversed"              => "Optional \"true\" when low values are good and high values are risky."
          }
        },
        {
          name: "period_comparison",
          description: "Side-by-side comparison table for multiple metrics across two explicit time windows.",
          params: {
            "metrics"             => "Comma-separated metric names (for example \"Burnout,Engagement\").",
            "period_a_start_date" => "Period A start date (YYYY-MM-DD).",
            "period_a_end_date"   => "Period A end date (YYYY-MM-DD).",
            "period_b_start_date" => "Period B start date (YYYY-MM-DD).",
            "period_b_end_date"   => "Period B end date (YYYY-MM-DD).",
            "period_a_label"      => "Optional label for period A (for example \"Last 30 days\").",
            "period_b_label"      => "Optional label for period B (for example \"Previous 30 days\")."
          }
        },
        {
          name: "group_comparison",
          description: "Compare one metric across several org groups defined in the Groups / GroupMembers tables.",
          params: {
            "metric"     => "Metric name (for example \"Psychological Safety\").",
            "start_date" => "Start date (YYYY-MM-DD).",
            "end_date"   => "End date (YYYY-MM-DD).",
            "groups"     => "Comma-separated group names that match Group records (for example \"Leaders,ICs\")."
          }
        },
        {
          name: "top_signals",
          description: "Table of top positive or negative signal categories within a time window.",
          params: {
            "metric"     => "Optional metric name to focus on (for example \"Burnout\").",
            "start_date" => "Start date (YYYY-MM-DD).",
            "end_date"   => "End date (YYYY-MM-DD).",
            "direction"  => "\"negative\" (default) or \"positive\".",
            "group_by"   => "\"category\" or \"subcategory\" (default \"subcategory\").",
            "top_n"      => "Optional number of rows to show (default 5)."
          }
        },
        {
          name: "event_impact",
          description: "Before/after bar comparison for a metric around a specific event date.",
          params: {
            "metric"     => "Metric name (for example \"Psychological Safety\").",
            "event_date" => "Event date (YYYY-MM-DD).",
            "pre_days"   => "Days before the event to aggregate (default 14).",
            "post_days"  => "Days after the event to aggregate (default 14)."
          }
        }
      ]
    end

    def self.build_list_groups(args, user:)
      workspace_id = args["workspace_id"]
      ws_ids = accessible_workspace_ids(user: user, workspace_id: workspace_id)
      return { groups: [] } if ws_ids.empty?

      scope = Group.where(workspace_id: ws_ids)

      if args["query"].present?
        q = "%#{args["query"].to_s.downcase}%"
        scope = scope.where("LOWER(name) LIKE ?", q)
      end

      groups = scope.order(:name).to_a

      member_counts = GroupMember.where(group_id: groups.map(&:id)).group(:group_id).count
      workspace_names = Workspace.where(id: ws_ids).pluck(:id, :name).to_h

      {
        groups: groups.map do |g|
          {
            id: g.id,
            name: g.name,
            workspace_id: g.workspace_id,
            workspace_name: workspace_names[g.workspace_id],
            member_count: member_counts[g.id].to_i
          }
        end
      }
    end

    # =========================================================================
    # Signal Category Tools
    # =========================================================================

    def self.build_list_signal_categories(args, user:)
      q = args["query"].to_s.strip.downcase

      submetric_id = nil
      if args["submetric"].present?
        sid = Integer(args["submetric"]) rescue nil
        submetric_id = sid if sid.to_i.positive?
        if submetric_id.nil?
          name = args["submetric"].to_s.strip
          submetric_id = submetric_ids_for([name]).first
        end
      end

      scope = SignalCategory.all
      scope = scope.where(submetric_id: submetric_id) if submetric_id.present?
      scope = scope.where("LOWER(name) LIKE ?", "%#{q}%") if q.present?

      submetric_info = Submetric.pluck(:id, :name, :metric_id).each_with_object({}) do |(id, name, mid), h|
        h[id] = { name: name, metric_id: mid }
      end
      metric_names = Metric.pluck(:id, :name).to_h

      rows = scope.order(:name).pluck(:id, :name, :submetric_id, :description).map do |id, name, sm_id, desc|
        sm = submetric_info[sm_id]
        {
          id: id,
          name: name,
          description: desc,
          submetric_id: sm_id,
          submetric_name: sm&.dig(:name),
          metric_id: sm&.dig(:metric_id),
          metric_name: metric_names[sm&.dig(:metric_id)]
        }
      end

      { signal_categories: rows }
    end

    def self.extract_signal_category_id_from_args(args)
      sc = args["signal_category"]
      if sc.present?
        sc_id = Integer(sc) rescue nil
        return sc_id if sc_id.to_i.positive?
        name = sc.to_s.strip
        return signal_category_ids_for([name]).first if name.present?
      end

      sc_id = args["signal_category_id"].to_i
      return sc_id if sc_id.positive?

      name = args["signal_category_name"].to_s.strip
      return nil if name.blank?
      signal_category_ids_for([name]).first
    end

    def self.signal_category_ids_for(names)
      ids_for(SignalCategory, names)
    end

    def self.build_signal_category_score(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] signal_category_score args=#{a.inspect} user_id=#{user.id}")

      end_date = a["end_date"].presence || Time.zone.now
      from, to  = rolling_30d_window_from_end(end_date)
      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      group_member_ids = integration_user_ids_from_group!(a, user: user)
      return group_member_ids if group_member_ids.is_a?(Hash) && group_member_ids[:error].present?

      # PRIVACY: Only accept group_id - direct integration_user_ids param removed for anonymity protection
      integration_user_ids = group_member_ids

      signal_category_id = extract_signal_category_id_from_args(a)

      # If no specific signal category, return all signal category scores
      if signal_category_id.nil?
        all_categories = SignalCategory.order(:name).pluck(:id, :name)
        scores = []

        all_categories.each do |sc_id, sc_name|
          result = dashboard_aligned_score(
            user: user,
            workspace_id: a["workspace_id"],
            start_date: from.to_date,
            end_date: to.to_date,
            signal_category_id: sc_id,
            integration_user_ids: integration_user_ids,
            group_id: a["group_id"]&.to_i,
            min_logit_margin: min_logit
          )

          scores << {
            signal_category_id: sc_id,
            signal_category_name: sc_name,
            score: result[:score],
            detections: result[:detections],
            ok: result[:ok]
          }
        end

        return {
          window: window_hash(from, to),
          end_date: to.to_date,
          scores: scores.sort_by { |s| -(s[:score] || 0) },
          dashboard_aligned: true
        }
      end

      # Single signal category score
      result = dashboard_aligned_score(
        user: user,
        workspace_id: a["workspace_id"],
        start_date: from.to_date,
        end_date: to.to_date,
        signal_category_id: signal_category_id,
        integration_user_ids: integration_user_ids,
        group_id: a["group_id"]&.to_i,
        min_logit_margin: min_logit
      )

      if !result[:ok]
        return {
          window: window_hash(from, to),
          end_date: to.to_date,
          signal_category_id: signal_category_id,
          score: nil,
          detections: result[:detections],
          ok: false,
          reason: "not_enough_data",
          min_required: 3,
          message: human_score_error_message({ reason: "not_enough_data", count: result[:detections], min_required: 3 }),
          dashboard_aligned: true
        }
      end

      {
        window: window_hash(from, to),
        end_date: to.to_date,
        signal_category_id: signal_category_id,
        score: result[:score],
        detections: result[:detections],
        ok: true,
        dashboard_aligned: true
      }
    end

    # =========================================================================
    # Insight Tools: score_delta, top_movers, group_gaps
    # =========================================================================

    def self.build_score_delta(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] score_delta args=#{a.inspect} user_id=#{user.id}")

      scope = (a["scope"] || "global").to_s
      compare = (a["compare"] || "30d").to_s
      end_date = Time.zone.now

      # Map the generic "name" param to scope-specific param
      if a["name"].present?
        case scope
        when "metric" then a["metric"] = a["name"]
        when "submetric" then a["submetric"] = a["name"]
        when "signal_category" then a["signal_category"] = a["name"]
        end
      end

      group_member_ids = integration_user_ids_from_group!(a, user: user)
      return group_member_ids if group_member_ids.is_a?(Hash) && group_member_ids[:error].present?

      # PRIVACY: Only accept group_id - direct integration_user_ids param removed for anonymity protection
      integration_user_ids = group_member_ids

      # Calculate current and comparison windows
      current_from, current_to = rolling_30d_window_from_end(end_date)

      compare_to = current_from - 1.second
      compare_from = case compare
        when "30d" then compare_to - 29.days
        when "90d" then compare_to - 89.days
        when "yoy" then current_from - 1.year
        else compare_to - 29.days
      end
      compare_to = current_from - 1.year + 29.days if compare == "yoy"

      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f
      base_opts = {
        user: user,
        workspace_id: a["workspace_id"],
        integration_user_ids: integration_user_ids,
        min_logit_margin: min_logit
      }

      # Get current and previous scores based on scope
      current_score = nil
      previous_score = nil
      current_res = nil
      previous_res = nil
      scope_name = nil
      scope_id = nil

      group_id = a["group_id"].to_i
      group_id = nil if group_id <= 0
      service = DashboardRollupService.new(
        workspace_id: a["workspace_id"],
        logit_margin_min: min_logit,
        group_member_ids: integration_user_ids,
        group_id: group_id
      )

      case scope
      when "global"
        current_score = dashboard_window_score(service, current_from.to_date, current_to.to_date, metric_id: nil, reverse: false)
        previous_score = dashboard_window_score(service, compare_from.to_date, compare_to.to_date, metric_id: nil, reverse: false)
        current_counts = service.aggregate_counts(start_date: current_from.to_date, end_date: current_to.to_date)
        previous_counts = service.aggregate_counts(start_date: compare_from.to_date, end_date: compare_to.to_date)
        current_res = { count: current_counts[:tot].to_i }
        previous_res = { count: previous_counts[:tot].to_i }
        scope_name = "Global"

      when "metric"
        metric_id = extract_metric_id_from_args(a)
        return { error: "name_required_for_metric_scope" } unless metric_id
        scope_id = metric_id
        metric = Metric.find_by(id: metric_id)
        scope_name = metric&.name || "Metric #{metric_id}"

        current_score = dashboard_window_score(service, current_from.to_date, current_to.to_date, metric_id: metric_id, reverse: metric&.reverse? || false)
        previous_score = dashboard_window_score(service, compare_from.to_date, compare_to.to_date, metric_id: metric_id, reverse: metric&.reverse? || false)
        current_counts = service.aggregate_counts(start_date: current_from.to_date, end_date: current_to.to_date, metric_id: metric_id)
        previous_counts = service.aggregate_counts(start_date: compare_from.to_date, end_date: compare_to.to_date, metric_id: metric_id)
        current_res = { count: current_counts[:tot].to_i }
        previous_res = { count: previous_counts[:tot].to_i }

      when "submetric"
        submetric_id = extract_submetric_id_from_args(a)
        return { error: "name_required_for_submetric_scope" } unless submetric_id
        scope_id = submetric_id
        scope_name = Submetric.where(id: submetric_id).pluck(:name).first || "Submetric #{submetric_id}"

        current_result = dashboard_aligned_score(
          user: user,
          workspace_id: a["workspace_id"],
          start_date: current_from.to_date,
          end_date: current_to.to_date,
          submetric_id: submetric_id,
          integration_user_ids: integration_user_ids,
          group_id: a["group_id"]&.to_i,
          min_logit_margin: min_logit
        )
        previous_result = dashboard_aligned_score(
          user: user,
          workspace_id: a["workspace_id"],
          start_date: compare_from.to_date,
          end_date: compare_to.to_date,
          submetric_id: submetric_id,
          integration_user_ids: integration_user_ids,
          group_id: a["group_id"]&.to_i,
          min_logit_margin: min_logit
        )
        current_score = current_result[:score]
        previous_score = previous_result[:score]
        current_res = { count: current_result[:detections] }
        previous_res = { count: previous_result[:detections] }

      when "signal_category"
        sc_id = extract_signal_category_id_from_args(a)
        return { error: "name_required_for_signal_category_scope" } unless sc_id
        scope_id = sc_id
        scope_name = SignalCategory.where(id: sc_id).pluck(:name).first || "Signal Category #{sc_id}"

        current_result = dashboard_aligned_score(
          user: user,
          workspace_id: a["workspace_id"],
          start_date: current_from.to_date,
          end_date: current_to.to_date,
          signal_category_id: sc_id,
          integration_user_ids: integration_user_ids,
          group_id: a["group_id"]&.to_i,
          min_logit_margin: min_logit
        )
        previous_result = dashboard_aligned_score(
          user: user,
          workspace_id: a["workspace_id"],
          start_date: compare_from.to_date,
          end_date: compare_to.to_date,
          signal_category_id: sc_id,
          integration_user_ids: integration_user_ids,
          group_id: a["group_id"]&.to_i,
          min_logit_margin: min_logit
        )
        current_score = current_result[:score]
        previous_score = previous_result[:score]
        current_res = { count: current_result[:detections] }
        previous_res = { count: previous_result[:detections] }
      end

      # Calculate delta and direction
      delta = nil
      direction = "stable"
      significant = false

      if current_score && previous_score
        delta = (current_score - previous_score).round(1)
        if delta > 2
          direction = "improving"
          significant = delta.abs > 5
        elsif delta < -2
          direction = "declining"
          significant = delta.abs > 5
        else
          direction = "stable"
        end
      end

      {
        scope: scope,
        name: scope_name,
        id: scope_id,
        compare: compare,
        current: {
          window: window_hash(current_from, current_to),
          score: current_score,
          detections: current_res&.dig(:count)
        },
        previous: {
          window: window_hash(compare_from, compare_to),
          score: previous_score,
          detections: previous_res&.dig(:count)
        },
        delta: delta,
        direction: direction,
        significant: significant,
        dashboard_aligned: true
      }
    end

    def self.build_top_movers(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] top_movers args=#{a.inspect} user_id=#{user.id}")

      direction_filter = (a["direction"] || "both").to_s
      scope = (a["scope"] || "metric").to_s
      limit = a["limit"].to_i
      limit = 5 if limit <= 0

      end_date = Time.zone.now
      current_from, current_to = rolling_30d_window_from_end(end_date)
      compare_to = current_from - 1.second
      compare_from = compare_to - 29.days

      group_member_ids = integration_user_ids_from_group!(a, user: user)
      return group_member_ids if group_member_ids.is_a?(Hash) && group_member_ids[:error].present?

      # PRIVACY: Only accept group_id - direct integration_user_ids param removed for anonymity protection
      integration_user_ids = group_member_ids

      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f
      base_opts = {
        user: user,
        workspace_id: a["workspace_id"],
        integration_user_ids: integration_user_ids,
        min_logit_margin: min_logit
      }

      movers = []

      if scope == "metric"
        metrics = Metric.order(:name).pluck(:id, :name)
        metrics.each do |mid, mname|
          current_result = dashboard_aligned_score(
            user: user,
            workspace_id: a["workspace_id"],
            start_date: current_from.to_date,
            end_date: current_to.to_date,
            metric_id: mid,
            integration_user_ids: integration_user_ids,
            group_id: a["group_id"]&.to_i,
            min_logit_margin: min_logit
          )
          previous_result = dashboard_aligned_score(
            user: user,
            workspace_id: a["workspace_id"],
            start_date: compare_from.to_date,
            end_date: compare_to.to_date,
            metric_id: mid,
            integration_user_ids: integration_user_ids,
            group_id: a["group_id"]&.to_i,
            min_logit_margin: min_logit
          )

          next unless current_result[:score] && previous_result[:score]

          delta = (current_result[:score] - previous_result[:score]).round(1)
          dir = delta > 0 ? "improving" : (delta < 0 ? "declining" : "stable")

          movers << {
            id: mid,
            name: mname,
            current_score: current_result[:score],
            previous_score: previous_result[:score],
            delta: delta,
            direction: dir,
            detections: current_result[:detections]
          }
        end
      else # submetric
        submetrics = Submetric.order(:name).pluck(:id, :name)
        submetrics.each do |sid, sname|
          current_result = dashboard_aligned_score(
            user: user,
            workspace_id: a["workspace_id"],
            start_date: current_from.to_date,
            end_date: current_to.to_date,
            submetric_id: sid,
            integration_user_ids: integration_user_ids,
            group_id: a["group_id"]&.to_i,
            min_logit_margin: min_logit
          )
          previous_result = dashboard_aligned_score(
            user: user,
            workspace_id: a["workspace_id"],
            start_date: compare_from.to_date,
            end_date: compare_to.to_date,
            submetric_id: sid,
            integration_user_ids: integration_user_ids,
            group_id: a["group_id"]&.to_i,
            min_logit_margin: min_logit
          )

          next unless current_result[:score] && previous_result[:score]

          delta = (current_result[:score] - previous_result[:score]).round(1)
          dir = delta > 0 ? "improving" : (delta < 0 ? "declining" : "stable")

          movers << {
            id: sid,
            name: sname,
            current_score: current_result[:score],
            previous_score: previous_result[:score],
            delta: delta,
            direction: dir,
            detections: current_result[:detections]
          }
        end
      end

      # Filter by direction
      filtered = case direction_filter
        when "improving" then movers.select { |m| m[:delta] > 0 }
        when "declining" then movers.select { |m| m[:delta] < 0 }
        else movers
      end

      # Sort by absolute delta descending
      sorted = filtered.sort_by { |m| -m[:delta].abs }

      {
        scope: scope,
        direction_filter: direction_filter,
        current_window: window_hash(current_from, current_to),
        compare_window: window_hash(compare_from, compare_to),
        movers: sorted.first(limit),
        dashboard_aligned: true
      }
    end

    def self.build_group_gaps(args, user:)
      a = args.deep_dup rescue args.dup
      Rails.logger.info("[AI_TOOL] group_gaps args=#{a.inspect} user_id=#{user.id}")

      scope = (a["scope"] || "global").to_s
      end_date = Time.zone.now
      from, to = rolling_30d_window_from_end(end_date)

      # Map the generic "name" param to scope-specific param
      if a["name"].present?
        case scope
        when "metric" then a["metric"] = a["name"]
        when "submetric" then a["submetric"] = a["name"]
        end
      end

      min_logit = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

      # Get all groups
      workspace_id = a["workspace_id"]
      ws_ids = accessible_workspace_ids(user: user, workspace_id: workspace_id)
      return { groups: [], error: "no_workspaces" } if ws_ids.empty?

      groups = Group.where(workspace_id: ws_ids).order(:name).to_a
      return { groups: [], error: "no_groups" } if groups.empty?

      # Determine scope filter
      scope_filter = {}
      scope_name = nil
      scope_id = nil

      case scope
      when "metric"
        metric_id = extract_metric_id_from_args(a)
        return { error: "name_required_for_metric_scope" } unless metric_id
        scope_filter[:metric_ids] = [metric_id]
        scope_id = metric_id
        scope_name = Metric.where(id: metric_id).pluck(:name).first || "Metric #{metric_id}"

      when "submetric"
        submetric_id = extract_submetric_id_from_args(a)
        return { error: "name_required_for_submetric_scope" } unless submetric_id
        scope_filter[:submetric_ids] = [submetric_id]
        scope_id = submetric_id
        scope_name = Submetric.where(id: submetric_id).pluck(:name).first || "Submetric #{submetric_id}"

      else # global
        scope_name = "Global"
      end

      group_scores = []

      groups.each do |g|
        member_ids = integration_user_ids_for_groups(
          group_ids: [g.id],
          group_names: [],
          user: user,
          workspace_id: workspace_id
        )

        next if member_ids.blank? || member_ids.size < 3

        result = dashboard_aligned_score(
          user: user,
          workspace_id: workspace_id,
          start_date: from.to_date,
          end_date: to.to_date,
          metric_id: scope_filter[:metric_ids]&.first,
          submetric_id: scope_filter[:submetric_ids]&.first,
          integration_user_ids: member_ids,
          group_id: g.id,
          min_logit_margin: min_logit
        )

        next unless result[:score] && result[:ok]

        group_scores << {
          group_id: g.id,
          group_name: g.name,
          score: result[:score].round(1),
          detections: result[:detections],
          member_count: member_ids.size
        }
      end

      # Sort by score descending (best first)
      sorted = group_scores.sort_by { |g| -(g[:score] || 0) }

      # Calculate gap analysis
      summary = nil
      if sorted.size >= 2
        highest = sorted.first
        lowest = sorted.last
        gap = (highest[:score] - lowest[:score]).round(1)
        gap_significance = gap > 15 ? "high" : (gap > 8 ? "medium" : "low")

        summary = {
          highest_group: highest[:group_name],
          highest_score: highest[:score],
          lowest_group: lowest[:group_name],
          lowest_score: lowest[:score],
          gap: gap,
          gap_significance: gap_significance
        }
      end

      {
        scope: scope,
        scope_name: scope_name,
        scope_id: scope_id,
        window: window_hash(from, to),
        groups: sorted,
        summary: summary,
        dashboard_aligned: true
      }
    end

    # -------- main router --------
    def self.call(name, args, user:)
      case name

      when "fetch_category_aggregate"
        a = normalize_facets_and_group!(args.dup)
        from = iso!(a["start_date"]); to = iso!(a["end_date"]).end_of_day
        group = (a["group_by"] || "category").to_sym

        agg = AiChat::DataQueries.window_aggregates(
          user: user,
          from: from, to: to,
          group_by: group,
          categories: Array(a["categories"]).presence,
          category_ids: a["category_ids"],
          workspace_id: a["workspace_id"],
          metric_ids:     (a["metric_ids"] || [])     + metric_ids_for(a["metric_names"]),
          submetric_ids:  (a["submetric_ids"] || [])  + submetric_ids_for(a["submetric_names"]),
          subcategory_ids:(a["subcategory_ids"] || [])+ subcategory_ids_for(a["subcategory_names"])
        )

        { group_by: group,
          window: { from: from.to_date, to: to.to_date },
          aggregates: agg }.to_json

      when "fetch_period_comparison", "period_comparison"
        a = normalize_facets_and_group!(args.dup)
        a_from = iso!(a.dig("period_a", "start_date")); a_to = iso!(a.dig("period_a", "end_date")).end_of_day
        b_from = iso!(a.dig("period_b", "start_date")); b_to = iso!(a.dig("period_b", "end_date")).end_of_day
        group  = (a["group_by"] || "category").to_sym

        common = {
          group_by: group,
          categories: Array(a["categories"]).presence,
          category_ids: a["category_ids"],
          workspace_id: a["workspace_id"],
          metric_ids:     (a["metric_ids"] || [])     + metric_ids_for(a["metric_names"]),
          submetric_ids:  (a["submetric_ids"] || [])  + submetric_ids_for(a["submetric_names"]),
          subcategory_ids:(a["subcategory_ids"] || [])+ subcategory_ids_for(a["subcategory_names"])
        }

        agg_a = AiChat::DataQueries.window_aggregates(user: user, from: a_from, to: a_to, **common)
        agg_b = AiChat::DataQueries.window_aggregates(user: user, from: b_from, to: b_to, **common)

        idx_b = agg_b.index_by { |r| r[:label] || r[:category] }
        cmp = agg_a.map do |r|
          key = r[:label] || r[:category]
          ob  = idx_b[key] || {}
          {
            label: key,
            a: r.slice(:total, :pos, :neg, :pos_rate, :neg_rate, :avg_logit),
            b: ob.slice(:total, :pos, :neg, :pos_rate, :neg_rate, :avg_logit),
            delta: {
              pos_rate: safe_delta(r[:pos_rate], ob[:pos_rate]),
              neg_rate: safe_delta(r[:neg_rate], ob[:neg_rate]),
              avg_logit: safe_delta(r[:avg_logit], ob[:avg_logit])
            }
          }
        end

        { group_by: group,
          period_a: { from: a_from.to_date, to: a_to.to_date },
          period_b: { from: b_from.to_date, to: b_to.to_date },
          comparison: cmp }.to_json

      when "fetch_timeseries", "time_series_data", "sparkline_chart"
        a = normalize_timeseries_facet!(args)
        from = iso!(a["start_date"]); to = iso!(a["end_date"]).end_of_day
          metric_kind = (a["metric"] || "pos_rate").to_sym

          metric_ids      = (a["metric_ids"] || [])     + metric_ids_for(a["metric_names"])
          submetric_ids   = (a["submetric_ids"] || [])  + submetric_ids_for(a["submetric_names"])
          subcategory_ids = (a["subcategory_ids"] || [])+ subcategory_ids_for(a["subcategory_names"])
          min_logit       = (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f

          points = AiChat::DataQueries.timeseries(
            user: user,
            category: a["category"],
            from: from, to: to,
            metric: metric_kind,
            metric_ids: metric_ids, submetric_ids: submetric_ids, subcategory_ids: subcategory_ids,
            workspace_id: a["workspace_id"],
            min_logit_margin: min_logit
          )

          label = series_label_for(
            a,
            metric_ids: metric_ids,
            submetric_ids: submetric_ids,
            subcategory_ids: subcategory_ids
          )
          title = "#{label} — #{metric_kind_label(metric_kind)}"

          sparkline_params = {
            category: a["category"], start_date: from.to_date, end_date: to.to_date,
            metric: metric_kind, workspace_id: a["workspace_id"],
            metric_ids: metric_ids, submetric_ids: submetric_ids, subcategory_ids: subcategory_ids,
            min_logit_margin: min_logit
          }
          token = AiChat::Sparkline.sign!(sparkline_params)
          url   = Rails.application.routes.url_helpers.ai_chat_sparkline_path(t: token)

          { title: title, metric: metric_kind, points: points,
            sparkline_url: url, sparkline_params: sparkline_params }.to_json

      when "topline_kpi_summary", "metrics_overview"
        build_topline_kpi_summary(args, user: user).to_json

      when "timeseries_bundle", "metrics_trend"
        build_timeseries_bundle(args, user: user).to_json

      when "driver_breakdown"
        build_driver_breakdown(args, user: user).to_json

      when "segment_compare", "group_comparison"
        build_segment_compare(args, user: user).to_json

      when "event_window_compare", "event_impact"
        build_event_window_compare(args, user: user).to_json

      when "root_cause_detector", "leading_indicator", "root_cause_analysis"
        build_root_cause_detector(args, user: user).to_json

      when "recommendation_brief", "recommendation_generator"
        build_recommendation_brief(args, user: user).to_json

      when "global_score"
        build_global_score(args, user: user).to_json

      when "metric_score"
        build_metric_score(args, user: user).to_json

      when "submetric_score"
        build_submetric_score(args, user: user).to_json

      when "compare_periods"
        build_compare_periods(args, user: user).to_json

      when "compare_groups"
        build_compare_groups(args, user: user).to_json

      when "trend_series"
        build_trend_series(args, user: user).to_json

      when "list_metrics"
        build_list_metrics(args, user: user).to_json

      when "list_submetrics"
        build_list_submetrics(args, user: user).to_json

      when "list_groups"
        build_list_groups(args, user: user).to_json

      when "list_signal_categories"
        build_list_signal_categories(args, user: user).to_json

      when "signal_category_score"
        build_signal_category_score(args, user: user).to_json

      when "score_delta"
        build_score_delta(args, user: user).to_json

      when "top_movers"
        build_top_movers(args, user: user).to_json

      when "group_gaps"
        build_group_gaps(args, user: user).to_json

      when "insight_plan"
        build_insight_plan(args, user: user).to_json

      when "key_takeaways"
        build_key_takeaways(args, user: user).to_json

      when "metric_deep_dive"
        build_metric_deep_dive(args, user: user).to_json

      when "submetric_breakdown"
        build_submetric_breakdown(args, user: user).to_json

      when "top_signals"
        build_top_signals(args, user: user).to_json

      when "signal_explain"
        build_signal_explain(args, user: user).to_json

      when "stats_analysis"
        build_stats_analysis(args, user: user).to_json

      when "top_group_signals"
        build_top_group_signals(args, user: user).to_json

      when "segment_trend"
        build_segment_trend(args, user: user).to_json

      when "group_trends"
        build_group_trends(args, user: user).to_json

      when "multi_event_analysis"
        build_multi_event_analysis(args, user: user).to_json

      when "keyword_filter"
        build_keyword_filter(args, user: user).to_json

      when "metric_relationship_summary", "correlation_analysis"
        build_correlation_analysis(args, user: user).to_json

      when "misalignment_detector"
        build_misalignment_detector(args, user: user).to_json

      when "search_guidance", "knowledge_base_query"
        kinds = args["kinds"].presence || %w[metric submetric signal_category signal_subcategory]
        hits  = AiChat::KnowledgeSearch.search(query: args["query"].to_s, kinds: kinds)
        {
          hits: hits.map { |h| h.slice(:title, :body, :namespace, :source_ref, :meta) }
        }.to_json

      when "benchmark_comparison"
        build_benchmark_comparison(args, user: user).to_json

      when "list_widgets"
        { widgets: available_widgets }.to_json

      when "batch_data_ops"
        ops = Array(args["operations"]).first(10)
        results, embeds = [], []

        ops.each_with_index do |op, i|
          tool = op["tool"]
          a    = (op["args"] || {}).dup

          # pre-normalize facets so the tool hits the right dimension
          if %w[fetch_category_aggregate fetch_period_comparison].include?(tool)
            a = normalize_facets_and_group!(a)
          elsif tool == "fetch_timeseries"
            a = normalize_timeseries_facet!(a)
          end

          r = call(tool, a, user: user)
          parsed = JSON.parse(r) rescue r
          results << { index: i, tool: tool, ok: true, data: parsed }

          # surface any sparkline found so the caller could embed them if desired
          if parsed.is_a?(Hash) && parsed["sparkline_url"]
            embeds << { kind: "sparkline", url: parsed["sparkline_url"], label: (parsed["title"] || "Chart") }
          end
        rescue => e
          results << { index: i, tool: tool, ok: false, error: e.message }
        end

        { results: results, embeds: embeds }.to_json

      else
        { error: "unknown_tool" }.to_json
      end
    end
  end
end


