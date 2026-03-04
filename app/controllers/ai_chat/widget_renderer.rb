# frozen_string_literal: true
module AiChat
  class WidgetRenderer
    class << self
      # Entry point. Returns [html, key]
      def render(kind:, user:, params: {}, points: nil, metric: "pos_rate", title: nil, width: 800, height: 260)
        case kind.to_s
        when "sparkline"
          render_sparkline(user: user, params: params, points: points, metric: metric, title: title, width: width, height: height)
        when "sparkline_chart"
          render_sparkline_chart(params: params, title: title)
        when "metric_gauge"
          render_metric_gauge(params: params, title: title)
        when "period_comparison"
          render_period_comparison(params: params, title: title)
        when "group_comparison"
          render_group_comparison(params: params, title: title)
        when "top_signals"
          render_top_signals(params: params, title: title)
        when "event_impact"
          render_event_impact(params: params, title: title)
        when "aggregate_gauge"
          render_aggregate_gauge(params: params, title: title)
        else
          ["", nil]
        end
      end

      private

      def render_aggregate_gauge(params:, title:)
        p = (params || {}).deep_symbolize_keys

        value        = p[:value].to_f              # 0–100, typically pos_rate * 100
        metric_name  = p[:metric_name] || title || "Current Health"
        trend_delta  = p[:trend_delta].to_f        # +/- % points vs baseline (0 if none)
        range_phrase = p[:range_phrase] || p[:range] || ""
        notch1       = (p[:notch1] || 25).to_i
        notch2       = (p[:notch2] || 75).to_i
        reversed     = !!p[:reversed]

        key = [
          "agg",
          metric_name.parameterize,
          value.round(1),
          notch1,
          notch2,
          reversed ? "rev" : "fwd"
        ].join("|")

        html = ApplicationController.render(
          partial: "ai_chat/widgets/aggregate_gauge",
          locals: {
            value:        value,
            metric_name:  metric_name,
            trend_delta:  trend_delta,
            range_phrase: range_phrase,
            notch1:       notch1,
            notch2:       notch2,
            reversed:     reversed
          }
        )

        [html, key]
      end

      def render_sparkline(user:, params:, points:, metric:, title:, width:, height:)
        p = (params || {}).deep_symbolize_keys

        # Build data (prefer tool-produced points; else compute)
        series =
          if points.present?
            points
          else
            from = parse_dateish(p[:start_date] || p[:from])
            to   = parse_dateish(p[:end_date]   || p[:to])
            AiChat::DataQueries.timeseries(
              user: user,
              category: p[:category],
              from: from, to: to,
              metric: (p[:metric] || metric || :pos_rate).to_sym,
              metric_ids: p[:metric_ids], submetric_ids: p[:submetric_ids], subcategory_ids: p[:subcategory_ids]
            )
          end

        # Scale values to 0..100 for the SVG partial
        metric_kind = (p[:metric] || metric || "pos_rate").to_s
        raw_vals    = Array(series).map { |r| (r.is_a?(Hash) ? (r[:value] || r["value"]) : r).to_f }
        pts =
          case metric_kind
          when "pos_rate","neg_rate","avg_logit"
            raw_vals.map { |v| (v * 100.0).round(6) }
          when "total"
            max = raw_vals.compact.max.to_f
            max.positive? ? raw_vals.map { |v| (v / max * 100.0).round(6) } : raw_vals.map { 0.0 }
          else
            raw_vals.map { |v| (v * 100.0).round(6) }
          end

        # Optional x-axis labels (MM/DD) when we have dates
        x_labels = Array(series).map do |r|
          d = r.is_a?(Hash) ? (r[:date] || r["date"]) : nil
          dd = d.is_a?(Date) || d.is_a?(Time) ? d.to_date : (Date.parse(d.to_s) rescue nil)
          dd ? dd.strftime("%-m/%-d") : ""
        end.presence

        key  = widget_key_for(p)
        html = ApplicationController.render(
          partial: "ai_chat/widgets/sparkline",
          locals: { points: pts, x_labels: x_labels, width: width, height: height, y_title: y_axis_title(metric_kind) }
        )
        [html, key]
      end

      # Lightweight sparkline widget used for inline blocks or block widgets.
      # Expects params[:values] OR params[:points] (array of numeric or {value:}).
      def render_sparkline_chart(params:, title:)
        p = (params || {}).deep_symbolize_keys

        raw_values = Array(p[:values] || p[:points]).map do |v|
          if v.is_a?(Hash)
            v[:value] || v["value"]
          else
            v
          end
        end.compact

        labels = Array(p[:labels] || p[:x_labels])

        subtitle = p[:subtitle]
        if !subtitle && p[:start_date].present? && p[:end_date].present?
          subtitle = "#{p[:start_date]} – #{p[:end_date]}"
        end

        html = ApplicationController.render(
          partial: "ai_chat/widgets/sparkline_chart",
          locals: {
            title:    title || p[:title],
            subtitle: subtitle,
            values:   raw_values,
            labels:   labels
          }
        )

        key = [
          "sparkline_chart",
          (title || p[:title] || "").to_s.parameterize,
          p[:metric] || "pos_rate",
          p[:start_date], p[:end_date]
        ].join("|")

        [html, key]
      end

      # Simple metric gauge widget; expects value in 0–100 or 0–1 (pos_rate).
      def render_metric_gauge(params:, title:)
        p = (params || {}).deep_symbolize_keys

        metric_name = p[:metric] || p[:metric_name] || title || "Metric"

        raw_value = p[:value] || p[:percent] || p[:pos_rate]
        numeric   = raw_value.to_f
        # treat 0–1 as rate; otherwise assume already in %
        numeric   = (numeric * 100.0) if numeric.positive? && numeric <= 1.0

        change = p[:change] || p[:delta] || p[:delta_pp]
        change_str =
          if change.is_a?(Numeric)
            format("%+.1f%%", change.to_f)
          else
            change.to_s
          end

        html = ApplicationController.render(
          partial: "ai_chat/widgets/metric_gauge",
          locals: {
            metric: metric_name,
            value:  numeric,
            change: change_str
          }
        )

        key = [
          "metric_gauge",
          metric_name.to_s.parameterize,
          numeric.round(1),
          change_str
        ].join("|")

        [html, key]
      end

      # Period comparison widget; expects either:
      # - params[:metrics] with formatted rows, or
      # - params[:comparison] from event/period tools.
      def render_period_comparison(params:, title:)
        p = (params || {}).deep_symbolize_keys

        period_a_label = p[:period_a_label] || p[:periodA] || "Period A"
        period_b_label = p[:period_b_label] || p[:periodB] || "Period B"

        rows = Array(p[:metrics])
        if rows.blank? && p[:comparison].is_a?(Array)
          rows = p[:comparison].map do |row|
            r = row.deep_symbolize_keys rescue row
            before = r[:before] || {}
            after  = r[:after]  || {}
            {
              name:  r[:metric] || "Metric",
              a:     format_percent_value(before[:pos_rate] || before["pos_rate"]),
              b:     format_percent_value(after[:pos_rate]  || after["pos_rate"]),
              delta: (r[:delta_pos_pp] || r["delta_pos_pp"])
            }
          end
        end

        html = ApplicationController.render(
          partial: "ai_chat/widgets/period_comparison",
          locals: {
            period_a_label: period_a_label,
            period_b_label: period_b_label,
            metrics:        rows
          }
        )

        key = [
          "period_comparison",
          period_a_label,
          period_b_label
        ].join("|")

        [html, key]
      end

      # Group comparison widget; expects params[:groups] or params[:segments].
      def render_group_comparison(params:, title:)
        p = (params || {}).deep_symbolize_keys

        metric_name = p[:metric_name] || p[:metric] || title || "Metric"
        groups_raw  = Array(p[:groups] || p[:segments])

        groups = groups_raw.map do |g|
          gg = g.deep_symbolize_keys rescue g
          {
            name:  gg[:name]  || gg[:label],
            pos:   gg[:pos]   || gg[:pos_rate] || gg["pos_rate"],
            neg:   gg[:neg]   || gg[:neg_rate] || gg["neg_rate"],
            total: gg[:total] || gg["total"]
          }
        end

        html = ApplicationController.render(
          partial: "ai_chat/widgets/group_comparison",
          locals: {
            metric_name: metric_name,
            groups:      groups
          }
        )

        key = [
          "group_comparison",
          metric_name.to_s.parameterize,
          groups.map { |g| g[:name].to_s.parameterize }.join(",")
        ].join("|")

        [html, key]
      end

      # Top signals widget; expects params[:signals] OR falls back to params[:drivers].
      def render_top_signals(params:, title:)
        p = (params || {}).deep_symbolize_keys

        direction = (p[:direction] || "negative").to_s
        heading   = title || p[:title] || "Top signals"

        signals_raw = Array(p[:signals])
        if signals_raw.blank? && p[:drivers].is_a?(Array)
          signals_raw = p[:drivers]
        end

        signals = signals_raw.map do |s|
          ss = s.deep_symbolize_keys rescue s
          value = ss[:value] || ss["value"]
          value ||= ss[:neg_rate] || ss["neg_rate"] || ss[:pos_rate] || ss["pos_rate"]
          value = format_percent_value(value) if value && !value.to_s.include?("%")

          {
            name:        ss[:name] || ss["name"] || ss[:label] || ss["label"] || ss[:category] || ss["category"],
            value:       value,
            count:       ss[:count] || ss["count"] || ss[:total] || ss["total"],
            description: ss[:description] || ss["description"]
          }
        end

        html = ApplicationController.render(
          partial: "ai_chat/widgets/top_signals",
          locals: {
            title:    heading,
            signals:  signals,
            direction: direction
          }
        )

        key = [
          "top_signals",
          direction,
          heading.to_s.parameterize
        ].join("|")

        [html, key]
      end

      # Event impact widget; expects params[:event_date] and either explicit before/after values
      # or a comparison array with :before/:after/:delta_pos_pp.
      def render_event_impact(params:, title:)
        p = (params || {}).deep_symbolize_keys

        metric_name  = p[:metric_name] || p[:metric] || title || "Metric"
        event_date   = p[:event_date].to_s
        before_label = p[:before_label] || "Before"
        after_label  = p[:after_label]  || "After"

        before_val = p[:before_value] || p[:before]
        after_val  = p[:after_value]  || p[:after]
        delta_lbl  = p[:delta_label]

        if (before_val.nil? || after_val.nil?) && p[:comparison].is_a?(Array)
          row = p[:comparison].first
          if row
            rr     = row.deep_symbolize_keys rescue row
            before = rr[:before] || {}
            after  = rr[:after]  || {}
            before_val ||= format_percent_value(before[:pos_rate] || before["pos_rate"])
            after_val  ||= format_percent_value(after[:pos_rate]  || after["pos_rate"])
            delta_lbl  ||= begin
              dp = rr[:delta_pos_pp] || rr["delta_pos_pp"]
              dp ? format("%+.1f pp", dp.to_f) : nil
            end
            metric_name ||= rr[:metric] || rr["metric"]
          end
        end

        html = ApplicationController.render(
          partial: "ai_chat/widgets/event_impact",
          locals: {
            metric_name:  metric_name,
            event_date:   event_date,
            before_label: before_label,
            after_label:  after_label,
            before_value: before_val,
            after_value:  after_val,
            delta_label:  delta_lbl
          }
        )

        key = [
          "event_impact",
          metric_name.to_s.parameterize,
          event_date
        ].join("|")

        [html, key]
      end

      def widget_key_for(p)
        m    = p[:metric] || "pos_rate"
        cat  = p[:category].to_s
        s    = (p[:start_date] || p[:from]).to_s
        e    = (p[:end_date]   || p[:to]).to_s
        mids = Array(p[:metric_ids]).map(&:to_i).sort.join("-")
        smid = Array(p[:submetric_ids]).map(&:to_i).sort.join("-")
        scid = Array(p[:subcategory_ids]).map(&:to_i).sort.join("-")
        [m, cat, s, e, mids, smid, scid].join("|")
      end

      def parse_dateish(v)
        return v if v.is_a?(Date)
        return v.to_date if v.respond_to?(:to_date)
        return nil if v.blank?
        Date.parse(v.to_s)
      rescue
        nil
      end

      def y_axis_title(metric)
        case metric.to_s
        when "pos_rate" then "Positive %"
        when "neg_rate" then "Negative %"
        when "avg_logit" then "Avg logit"
        when "total" then "Total (norm.)"
        else metric.to_s.humanize
        end
      end

      def format_percent_value(value)
        return nil if value.nil?
        "#{(value.to_f * 100.0).round(1)}%"
      end
    end
  end
end
