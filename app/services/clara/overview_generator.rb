module Clara
  class OverviewGenerator
    DEFAULT_MODEL       = ENV.fetch("CLARA_OVERVIEW_MODEL", ENV.fetch("OPENAI_CHAT_MODEL", "gpt-4o-mini"))
    DEFAULT_TEMPERATURE = (ENV["CLARA_OVERVIEW_TEMPERATURE"] || "0.35").to_f
    MAX_OUTPUT_TOKENS   = (ENV["CLARA_OVERVIEW_MAX_TOKENS"] || "500").to_i

    def initialize(overview:, workspace:, metric:, stream_key:, model: DEFAULT_MODEL, logit_margin_threshold: nil, range_start:, range_end:, member_ids:, logger: Rails.logger, prompt_override: nil)
      @overview               = overview
      @workspace              = workspace
      @metric                 = metric
      @stream_key             = stream_key
      @model                  = model.presence || DEFAULT_MODEL
      @range_start            = range_start.to_date
      @range_end              = range_end.to_date
      @member_ids             = member_ids
      @logger                 = logger
      @prompt_override        = prompt_override
    end

    def run!
      @overview.update!(
        status:       :generating,
        generated_at: Time.current,
        openai_model: @model,
        error_message: nil,
        content:      nil
      )

      snapshot = build_snapshot
      broadcast_status("generating", snapshot: snapshot)

      buffer = +""
      client = OpenAI::Client.new

      client.responses.create(
        parameters: {
          model: @model,
          temperature: DEFAULT_TEMPERATURE,
          max_output_tokens: MAX_OUTPUT_TOKENS,
          input: prompt_for(snapshot),
          stream: proc { |chunk, _event| handle_chunk(chunk, buffer) }
        }
      )

      final_text = buffer.strip

      @overview.update!(
        content:      final_text,
        status:       :ready,
        generated_at: Time.current,
        expires_at:   Time.current + Clara::OverviewService::EXPIRATION_WINDOW
      )

      broadcast_complete(final_text)
    rescue => e
      @logger.error("[Clara::OverviewGenerator] overview_id=#{@overview.id} #{e.class}: #{e.message}")
      @overview.update_columns(
        status:        "failed",
        error_message: e.message.to_s[0, 1000]
      )
      broadcast_error("CLARA could not generate a new overview right now.")
    end

    # Generates a one-off preview without mutating the overview or broadcasting.
    def preview!(prompt_override: nil)
      snapshot = build_snapshot
      prompt   = prompt_for(snapshot, prompt_override: prompt_override.presence || @prompt_override)

      resp = OpenAI::Client.new.responses.create(
        parameters: {
          model: @model,
          temperature: DEFAULT_TEMPERATURE,
          max_output_tokens: MAX_OUTPUT_TOKENS,
          input: prompt
        }
      )

      [extract_text_from_response(resp).to_s.strip, snapshot]
    rescue => e
      @logger.error("[Clara::OverviewGenerator] preview failed #{e.class}: #{e.message}")
      ["[preview failed: #{e.message}]", nil]
    end

    private

    def handle_chunk(chunk, buffer)
      case chunk["type"]
      when "response.output_text.delta"
        delta = chunk["delta"].to_s
        return if delta.empty?

        buffer << delta
        broadcast_token(delta)
      when "response.error"
        message = chunk.dig("error", "message")
        raise StandardError, message if message.present?
      end
    end

    def build_snapshot
      window_start = @range_start.beginning_of_day
      window_end   = @range_end.end_of_day
      lookback_start = (@range_start - 29.days).beginning_of_day

      scope = detection_scope(lookback_start, window_end)

      # Use the same rollup-backed/fallback path as dashboard metric views
      # for top-line metric math so CLARA numbers stay in lockstep with UI.
      rollup_service = DashboardRollupService.new(
        workspace_id: @workspace.id,
        logit_margin_min: (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f,
        group_member_ids: @member_ids
      )
      daily = rollup_service.daily_counts(
        start_date: lookback_start.to_date,
        end_date: window_end.to_date,
        metric_id: @metric.id
      )
      scores = rolling30_scores(daily, @range_start, @range_end, reverse: @metric.reverse?)

      category_daily = daily_counts_by_label(scope, label_column: "signal_categories.name")
      submetric_daily = daily_counts_by_label(scope, label_column: "submetrics.name")

      category_scores = group_scores(category_daily, @range_start, @range_end, reverse: @metric.reverse?)
      submetric_scores = group_scores(submetric_daily, @range_start, @range_end, reverse: @metric.reverse?)

      tailwinds_categories, headwinds_categories =
        split_tail_head(category_scores, limit: 3)
      tailwinds_submetrics, headwinds_submetrics =
        split_tail_head(submetric_scores, limit: 2)

      weakest_submetric = weakest_group(submetric_scores)
      submetric_correlations = submetric_correlations(submetric_daily, window_end, reverse: @metric.reverse?)

      score_start = scores[:start_score].round
      score_end   = scores[:end_score].round

      {
        window_start: window_start,
        window_end:   window_end,
        score_start:  score_start,
        score_end:    score_end,
        score_delta:  score_end - score_start,
        tailwinds_categories: tailwinds_categories,
        headwinds_categories: headwinds_categories,
        tailwinds_submetrics: tailwinds_submetrics,
        headwinds_submetrics: headwinds_submetrics,
        weakest_submetric: weakest_submetric,
        submetric_correlations: submetric_correlations
      }
    end

    def detection_scope(start_ts, end_ts)
      scope = Detection
                .joins(message: :integration, signal_category: :submetric)
                .where(integrations: { workspace_id: @workspace.id })
                .where(submetrics: { metric_id: @metric.id })
                .where("messages.posted_at >= ? AND messages.posted_at <= ?", start_ts, end_ts)
                .with_scoring_policy

      if @member_ids
        scope = scope.where(messages: { integration_user_id: @member_ids })
      end

      scope
    end

    def daily_counts(scope)
      pos_expr = Arel.sql("SUM(CASE WHEN detections.polarity = 'positive' THEN 1 ELSE 0 END)")
      tot_expr = Arel.sql("COUNT(*)")

      rows =
        scope
          .group(Arel.sql("DATE(messages.posted_at)"))
          .pluck(Arel.sql("DATE(messages.posted_at)"), pos_expr, tot_expr)

      daily = Hash.new { |h, k| h[k] = { pos: 0, tot: 0 } }
      rows.each do |day, pos, tot|
        d = day.to_date
        daily[d][:pos] = pos.to_i
        daily[d][:tot] = tot.to_i
      end
      daily
    end

    def daily_counts_by_label(scope, label_column:)
      pos_expr = Arel.sql("SUM(CASE WHEN detections.polarity = 'positive' THEN 1 ELSE 0 END)")
      tot_expr = Arel.sql("COUNT(*)")

      rows =
        scope
          .group(label_column, Arel.sql("DATE(messages.posted_at)"))
          .pluck(label_column, Arel.sql("DATE(messages.posted_at)"), pos_expr, tot_expr)

      by_label = Hash.new do |h, k|
        h[k] = Hash.new { |hh, dd| hh[dd] = { pos: 0, tot: 0 } }
      end

      rows.each do |label, day, pos, tot|
        next if label.blank?
        d = day.to_date
        key = label.to_s
        by_label[key][d][:pos] = pos.to_i
        by_label[key][d][:tot] = tot.to_i
      end

      by_label
    end

    def rolling30_scores(daily, range_start, range_end, reverse: false)
      start_day = range_start.to_date
      end_day   = range_end.to_date
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

      score_for = lambda do |end_d|
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

      {
        start_score: score_for.call(start_day),
        end_score: score_for.call(end_day)
      }
    end

    def group_scores(daily_by_label, range_start, range_end, reverse: false)
      window_end = range_end.to_date
      window_start = range_start.to_date
      last30_start = window_end - 29.days

      daily_by_label.map do |label, daily|
        last30_total = 0
        (last30_start..window_end).each do |dd|
          last30_total += daily[dd][:tot].to_i
        end
        next if last30_total <= 0

        scores = rolling30_scores(daily, window_start, window_end, reverse: reverse)
        start_raw = scores[:start_score]
        end_raw = scores[:end_score]
        start_round = start_raw.round
        end_round = end_raw.round
        {
          label: label,
          start_score: start_round,
          end_score: end_round,
          delta: end_round - start_round,
          end_score_raw: end_raw
        }
      end.compact
    end

    def split_tail_head(groups, limit:)
      rows = Array(groups)
      return [[], []] if rows.empty?

      rows = rows.map do |row|
        row.merge(health_score: (row[:end_score_raw] || row[:end_score]).to_f)
      end

      tailwinds = rows.sort_by { |row| -row[:health_score].to_f }.first(limit)
      headwinds = rows.sort_by { |row| row[:health_score].to_f }.first(limit)
      [tailwinds, headwinds]
    end

    def weakest_group(groups)
      rows = Array(groups)
      return nil if rows.empty?

      rows.min_by { |row| (row[:end_score_raw] || row[:end_score]).to_f }
    end

    def submetric_correlations(daily_by_label, window_end, reverse: false, min_days: 12, min_total: 8)
      return [] if daily_by_label.blank?

      window_end = window_end.to_date
      lookback_start = window_end - 29.days

      days = (lookback_start..window_end).to_a
      idx = {}
      days.each_with_index { |d, i| idx[d] = i }

      overall_daily = Hash.new { |h, k| h[k] = { pos: 0, tot: 0 } }
      daily_by_label.each_value do |daily|
        days.each do |d|
          overall_daily[d][:pos] += daily[d][:pos].to_i
          overall_daily[d][:tot] += daily[d][:tot].to_i
        end
      end

      overall_series = rolling30_series(overall_daily, days, reverse: reverse)

      daily_by_label.map do |label, daily|
        total = days.sum { |d| daily[d][:tot].to_i }
        next if total < min_total

        series = rolling30_series(daily, days, reverse: reverse)
        corr = pearson_corr(overall_series, series)
        next if corr.nil? || corr.nan?

        { label: label, r: corr.round(2), total: total }
      end.compact
        .select { |row| row[:r].abs >= 0.35 }
        .sort_by { |row| -row[:r].abs }
        .first(3)
    end

    def rolling30_series(daily, days, reverse: false)
      cum_pos = Array.new(days.size + 1, 0)
      cum_tot = Array.new(days.size + 1, 0)

      days.each_with_index do |d, i|
        pos = daily[d][:pos] rescue 0
        tot = daily[d][:tot] rescue 0
        cum_pos[i + 1] = cum_pos[i] + pos.to_i
        cum_tot[i + 1] = cum_tot[i] + tot.to_i
      end

      series = []
      days.each_with_index do |d, i|
        s = [i - 29, 0].max
        pos = cum_pos[i + 1] - cum_pos[s]
        tot = cum_tot[i + 1] - cum_tot[s]
        pct = tot > 0 ? (pos.to_f / tot.to_f) * 100.0 : 50.0
        pct = 100.0 - pct if reverse
        series << pct
      end
      series
    end

    def pearson_corr(series_a, series_b)
      return nil if series_a.blank? || series_b.blank?

      n = [series_a.length, series_b.length].min
      return nil if n < 12

      a = series_a.first(n)
      b = series_b.first(n)

      mean_a = a.sum.to_f / n
      mean_b = b.sum.to_f / n

      num = 0.0
      den_a = 0.0
      den_b = 0.0

      n.times do |i|
        da = a[i] - mean_a
        db = b[i] - mean_b
        num += da * db
        den_a += da * da
        den_b += db * db
      end

      return nil if den_a <= 0.0 || den_b <= 0.0

      num / Math.sqrt(den_a * den_b)
    end

    def prompt_for(snapshot, prompt_override: nil)
      score_start = format_score(snapshot[:score_start])
      score_end   = format_score(snapshot[:score_end])
      score_delta = format_delta_points(snapshot[:score_delta])

      tail_cats = format_driver_list(snapshot[:tailwinds_categories])
      head_cats = format_driver_list(snapshot[:headwinds_categories])
      tail_subs = format_driver_list(snapshot[:tailwinds_submetrics])
      head_subs = format_driver_list(snapshot[:headwinds_submetrics])

      weakest_submetric = snapshot[:weakest_submetric]
      weakest_submetric_label = weakest_submetric ? weakest_submetric[:label] : "None"
      weakest_submetric_score = weakest_submetric ? format_score(weakest_submetric[:end_score]) : "n/a"
      weakest_submetric_delta = weakest_submetric ? format_delta_points(weakest_submetric[:delta]) : "n/a"

      correlations = format_correlation_list(snapshot[:submetric_correlations])

      polarity = @metric.reverse? ? "Lower values mean healthier performance for this metric." : "Higher values mean healthier performance for this metric."
      system_prompt = prompt_override.presence ||
                      PromptVersion.active_content("clara_overview") ||
                      default_system_prompt

      [
        {
          role:    "system",
          content: system_prompt.to_s.strip
        },
        {
          role:    "user",
          content: <<~USR.strip
            Workspace: #{@workspace.name}
            Metric: #{@metric.name}
            Direction: #{polarity}
            Window: #{window_label(snapshot[:window_start], snapshot[:window_end])}
            Score at window start: #{score_start}
            Score at window end: #{score_end}
            Score change (end - start): #{score_delta} points
            Tailwinds (submetrics): #{tail_subs}
            Headwinds (submetrics): #{head_subs}
            Weakest submetric: #{weakest_submetric_label} (#{weakest_submetric_score}, delta #{weakest_submetric_delta})
            Submetric correlations (rolling 30d, daily): #{correlations}
            Guidance: Write for a CEO/CPO/HR leader who wants the answer to: "Are we healthy on this metric, is it moving in the right direction, and what is most driving it right now?" Use the polarity to interpret healthy vs unhealthy. Use point deltas (not percentages). Use ONLY submetrics for drivers; do not mention signal categories. Call out both the strongest tailwinds and the riskiest headwinds. Keep language concrete and executive-friendly. Include one concrete, operational next action tied to the weakest submetric; avoid vague phrasing (no "keep an eye on," "pay attention to," or "focus on"). If no submetric is clearly low (or the weakest submetric is "None"), reinforce what's strong and give a specific maintain action tied to the strongest tailwind submetric. If the correlation list includes any strong relationships, briefly mention the single strongest one and what it implies; otherwise skip correlations entirely.
          USR
        }
      ]
    end

    def default_system_prompt
      <<~SYS.strip
        # Previous prompt (kept for reference)
        # You are an executive culture intelligence analyst for Workplace. Your job is to write a concise, high-trust summary of how the organization is trending on the requested metric during the given window.
        # Output: 3–4 sentences, plain text only (no bullets, no headings, no markdown). Write like a seasoned operator or consultant briefing a CEO: clear, direct, action-oriented.
        # Use ONLY the provided inputs. Do not invent causes, events, teams, or examples. Do not reference methodology, thresholds, data sparsity, detection counts, or limitations. If confidence is unclear, use careful language (e.g., "signals suggest" / "appears") while still being decisive.
        # Include, in this order:
        # 1) Current state and directionality (healthy vs. unhealthy based on the metric's polarity and current score).
        # 2) Movement within the window (use the point change from window start to window end).
        # 3) The strongest tailwinds and headwinds using the provided categories or submetrics as likely drivers, without over-explaining.

        You are an executive culture intelligence analyst for Workplace. Write a single, tight paragraph (3–4 sentences, plain text only) that is clear, direct, and action-oriented.
        Use ONLY the provided inputs. Do not invent causes, events, teams, or examples. Do not reference methodology, thresholds, data sparsity, detection counts, or limitations.
        Avoid heavy numbers; use at most one numeric callout if it materially changes the story.

        Include, in this order:
        1) Current state + direction (healthy vs unhealthy based on polarity and current score).
        2) What’s driving it (strongest tailwinds and headwinds, named but not over‑explained).
        3) What to do next (one concise, implied operational focus).
      SYS
    end

    def window_label(start_ts, end_ts)
      "#{start_ts.strftime('%b %-d')} to #{end_ts.strftime('%b %-d')}"
    end

    def format_score(value)
      return "n/a" if value.nil?

      value.round.to_i.to_s
    end

    def format_delta_points(value)
      return "n/a" if value.nil?

      diff = value.round.to_i
      return "+0" if diff.zero?
      diff.positive? ? "+#{diff}" : diff.to_s
    end

    def format_driver_list(rows)
      list =
        Array(rows).map do |row|
          next if row.blank?
          score = format_score(row[:end_score])
          delta = format_delta_points(row[:delta])
          "#{row[:label]} (#{score}, delta #{delta})"
        end.compact

      list.join(", ").presence || "None"
    end

    def format_correlation_list(rows)
      list =
        Array(rows).map do |row|
          next if row.blank?
          r = row[:r]
          "#{row[:label]} (r=#{r})"
        end.compact

      list.join(", ").presence || "None"
    end

    def broadcast_token(delta)
      ActionCable.server.broadcast(
        @stream_key,
        {
          type:        "token",
          token:       delta,
          overview_id: @overview.id
        }
      )
    end

    def broadcast_status(status, snapshot:)
      ActionCable.server.broadcast(
        @stream_key,
        {
          type:        "status",
          status:      status,
          overview_id: @overview.id,
          snapshot:    snapshot
        }
      )
    end

    def broadcast_complete(final_text)
      ActionCable.server.broadcast(
        @stream_key,
        {
          type:     "complete",
          overview: Clara::OverviewService.serialize(@overview),
          content:  final_text
        }
      )
    end

    def broadcast_error(message)
      ActionCable.server.broadcast(
        @stream_key,
        {
          type:    "error",
          message: message,
          overview_id: @overview.id
        }
      )
    end

    def extract_text_from_response(resp)
      items = Array(resp["output"])
      chunks =
        items.flat_map do |item|
          content = item["content"]
          next [] unless content.is_a?(Array)

          content.filter_map do |c|
            if c.is_a?(Hash) && c["type"] == "output_text"
              c["text"].to_s
            end
          end
        end
      chunks.join
    end
  end
end

