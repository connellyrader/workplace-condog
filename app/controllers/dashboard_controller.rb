class DashboardController < ApplicationController
  include DashboardRollups

  skip_before_action :lucas_only, only: [:not_lucas]
  skip_before_action :authenticate_user!, only: [:not_lucas]
  before_action :set_persistent_range, only: [:index, :metric]
  before_action :set_persistent_group, only: [:index, :metric, :insights]
  before_action :show_right_panel, only: [:index, :metric, :docs]
  before_action :load_topbar_groups, only: [:index, :metric]
  before_action :disable_turbo_cache

  # ====== MAIN DASHBOARD ======
  def index
    @topbar_title = "Dashboard"

    # Redirect partners without client workspaces to partner dashboard
    if @active_workspace.nil? && current_user&.partner?
      return redirect_to partner_dashboard_path
    end
    
    # Regular users must have an active workspace
    unless @active_workspace
      flash[:alert] = "No workspace available. Please contact support."
      return redirect_to root_path
    end

    #all_time_sentinel = Date.new(2000, 1, 1)
    #@is_all_time = (params[:start].present? && Date.parse(params[:start]) == all_time_sentinel rescue false)

    wid = @active_workspace.id

    # -------------------------------------------------------------------------
    # Solution A: clamp ALL-TIME to scored detections (workspace + group)
    # -------------------------------------------------------------------------
    if @is_all_time
      min_rollup_day, max_rollup_day = rollup_date_bounds

      if min_rollup_day && max_rollup_day
        @range_start = min_rollup_day
        @range_end   = [max_rollup_day, Time.zone.today].min
      else
        clamp_scope =
          Detection
            .joins(message: :integration)
            .where(integrations: { workspace_id: wid })
            .merge(Detection.with_scoring_policy)

        clamp_scope = apply_group_filter(clamp_scope, @group_member_ids)

        min_posted = clamp_scope.minimum("messages.posted_at")
        max_posted = clamp_scope.maximum("messages.posted_at")

        if min_posted && max_posted
          @range_start = min_posted.to_date
          @range_end   = [max_posted.to_date, Time.zone.today].min
        end
      end
    end

    days = (@range_end - @range_start).to_i + 1

    # Base scope for last100 (keep as selected window)
    curr_start_ts = @range_start.beginning_of_day
    curr_end_ts   = @range_end.end_of_day

    base_curr =
      Detection
        .joins(message: :integration)
        .where(integrations: { workspace_id: wid })
        .where("messages.posted_at >= ? AND messages.posted_at <= ?", curr_start_ts, curr_end_ts)
        .merge(Detection.with_scoring_policy)

    base_curr = apply_group_filter(base_curr, @group_member_ids)

    last100_scope =
      Detection
        .joins(message: :integration)
        .where(integrations: { workspace_id: wid })
        .merge(Detection.with_scoring_policy)

    last100_scope = apply_group_filter(last100_scope, @group_member_ids)

    last100_cache_key = ["dash-last100-v2", wid, (@group_scope || "all")].join(":")
    @last100 = Rails.cache.fetch(last100_cache_key, expires_in: 45.seconds) do
      last_detections_from_recent_messages(last100_scope, limit: 100)
    end

    @days_analyzed = Integration.where(workspace_id: wid).maximum(:days_analyzed).to_i
    @metrics = Metric.order(:sort).to_a

    # Cache expensive dashboard computations briefly to make workspace switching feel snappy.
    # Safe because freshness tolerance here is seconds, not minutes.
    cache_key = [
      "dash-index-v4",
      wid,
      @range_start.to_date,
      @range_end.to_date,
      (@group_scope || "all"),
      @is_all_time ? 1 : 0,
      request.format.json? ? "json" : "html"
    ].join(":")

    cache_ttl = dashboard_cache_ttl(days: days, is_json: request.format.json?)

    cached = Rails.cache.fetch(cache_key, expires_in: cache_ttl) do
      # -------------------------------------------------------------------------
      # Permanent gauge score + chart points (rolling 90; 29-day lookback)
      # Uses pre-computed rollups for speed (falls back to raw detections if unavailable)
      # -------------------------------------------------------------------------
      series_start = @range_start - 29.days
      series_end = @range_end

      daily = fetch_daily_counts(start_date: series_start, end_date: series_end)

      # Anchor dates across selected range (inclusive)
      span = days
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

      anchors = []
      d = @range_start.to_date
      while d <= @range_end.to_date
        anchors << d
        d += step.days
      end
      anchors << @range_end.to_date unless anchors.last == @range_end.to_date
      anchors.uniq!

      # Cum sums across (range_start-29 .. range_end)
      lookback_day = @range_start.to_date - 29.days
      days_series  = (lookback_day..@range_end.to_date).to_a

      idx = {}
      cum_pos = Array.new(days_series.size + 1, 0)
      cum_tot = Array.new(days_series.size + 1, 0)

      days_series.each_with_index do |dd, i|
        idx[dd] = i
        cum_pos[i + 1] = cum_pos[i] + daily[dd][:pos].to_i
        cum_tot[i + 1] = cum_tot[i] + daily[dd][:tot].to_i
      end

      rolling90 = ->(end_day) do
        end_day = end_day.to_date
        start_day = end_day - 29.days
        start_day = [start_day, lookback_day].max

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

      pts = anchors.map { |ad| rolling90.call(ad).round }
      pts = [pts.first, pts.first] if pts.size < 2

      metric_counts = fetch_metric_counts(start_date: @range_start, end_date: @range_end)

      {
        spark_points: pts,
        metric_counts: metric_counts,
        metric_card_data: build_metric_card_data(metrics: @metrics, metric_counts: metric_counts)
      }
    end

    @spark_points = cached[:spark_points]
    @value = @spark_points.last.to_i
    @trend_delta = (@spark_points.last.to_i - @spark_points.first.to_i)
    @trend_arrow = @trend_delta >= 0 ? "up" : "down"
    @trend_delta_abs = @trend_delta.abs

    @notch1, @notch2 = 25, 75
    @range =
      if @value < @notch1 then "low"
      elsif @value < @notch2 then "mid"
      else "high"
      end

    @range_phrase =
      if days <= 60
        "in #{helpers.pluralize(days, "day")}"
      elsif days < 730
        months = (days / 30.0).round
        "in #{helpers.pluralize(months, "month")}"
      else
        years = (days / 365.0).round
        "in #{helpers.pluralize(years, "year")}"
      end

    Rails.logger.info "[RangeDebug] start=#{@range_start} end=#{@range_end} tz_today=#{Time.zone.today} cache=#{cached.present?}"

    @metric_counts = cached[:metric_counts]
    @metric_card_data = cached[:metric_card_data]

    respond_to do |format|
      format.html
      format.json do
        render json: {
          metric_boxes: render_to_string(
            partial:    "dashboard/components/metric_box",
            collection: @metrics,
            as:         :metric,
            formats:    [:html]
          ),
          gauge: render_to_string(
            partial: "dashboard/components/gauge",
            formats: [:html]
          ),
          last100: render_to_string(
            partial: "dashboard/components/signals",
            formats: [:html]
          )
        }
      end
    end
  end

  def metric
    wid = @active_workspace.id

    @days_analyzed = Integration.where(workspace_id: wid).maximum(:days_analyzed).to_i
    if @days_analyzed < 30
      respond_to do |format|
        format.html do
          redirect_to dashboard_path, alert: "This metric is available after at least 60 days are analyzed."
        end
        format.json do
          render json: { ok: false, error: "insufficient_data", days_analyzed: @days_analyzed },
                 status: :unprocessable_entity
        end
      end
      return
    end

    @metric       = Metric.find(params[:id])
    @topbar_title = @metric.name
    @back_path    = dashboard_path

    #all_time_sentinel = Date.new(2000, 1, 1)
    #@is_all_time = (params[:start].present? && Date.parse(params[:start]) == all_time_sentinel rescue false)
    @is_all_time = !!session[:dash_is_all_time]

    # -------------------------------------------------------------------------
    # Solution A: clamp ALL-TIME to scored detections (workspace + metric + group)
    # -------------------------------------------------------------------------
    if @is_all_time
      min_rollup_day, max_rollup_day = rollup_date_bounds(metric_id: @metric.id)

      if min_rollup_day && max_rollup_day
        @range_start = min_rollup_day
        @range_end   = [max_rollup_day, Time.zone.today].min
      else
        clamp_scope =
          Detection
            .joins(message: :integration, signal_category: :submetric)
            .where(integrations: { workspace_id: wid })
            .merge(Detection.with_scoring_policy)
            .where(submetrics: { metric_id: @metric.id })

        clamp_scope = apply_group_filter(clamp_scope, @group_member_ids)

        min_posted = clamp_scope.minimum("messages.posted_at")
        max_posted = clamp_scope.maximum("messages.posted_at")

        if min_posted && max_posted
          @range_start = min_posted.to_date
          @range_end   = [max_posted.to_date, Time.zone.today].min
        end
      end
    end

    days = (@range_end - @range_start).to_i + 1

    @range_phrase =
      if days <= 60
        "in #{helpers.pluralize(days, "day")}"
      elsif days < 730
        months = (days / 30.0).round
        "in #{helpers.pluralize(months, "month")}"
      else
        years = (days / 365.0).round
        "in #{helpers.pluralize(years, "year")}"
      end

    curr_start_ts = @range_start.beginning_of_day
    curr_end_ts   = @range_end.end_of_day

    base_curr =
      Detection
        .joins(message: :integration, signal_category: :submetric)
        .where(integrations: { workspace_id: wid })
        .where("messages.posted_at >= ? AND messages.posted_at <= ?", curr_start_ts, curr_end_ts)
        .merge(Detection.with_scoring_policy)
        .where(submetrics: { metric_id: @metric.id })

    base_curr = apply_group_filter(base_curr, @group_member_ids)

    @min_detections         = Clara::OverviewService::MIN_DETECTIONS
    @metric_detection_count = base_curr.count
    @score_available        = @metric_detection_count >= @min_detections

    @clara_overview = nil
    if @score_available
      clara_service = Clara::OverviewService.new(
        workspace:   @active_workspace,
        metric:      @metric,
        user:        current_user,
        range_start: @range_start,
        range_end:   @range_end,
        group_scope: @group_scope,
        member_ids:  @group_member_ids
      )
      @clara_overview = clara_service.latest
    end

    last100_scope =
      Detection
        .joins(message: :integration, signal_category: :submetric)
        .where(integrations: { workspace_id: wid })
        .merge(Detection.with_scoring_policy)
        .where(submetrics: { metric_id: @metric.id })

    last100_scope = apply_group_filter(last100_scope, @group_member_ids)
    @last100 = last_detections_from_recent_messages(last100_scope, limit: 100)

    # NOTE: We now show last-30-day counts (not full-range counts) because scores
    # are calculated from rolling 30-day windows. Showing full-range counts next to
    # a 30-day score was confusing (e.g., "13 detections" but "--" score because
    # only 2 of those 13 were in the last 30 days).
    # The actual last30 counts are populated below in the submetric/category loops.
    @submetric_detection_counts = {}
    @signal_category_detection_counts = {}

    @signal_category_rates = {}

    @submetric_rates = {}
    @submetric_last30_counts = {}

    @notch1, @notch2 = 25, 75

    pos_expr = Arel.sql("SUM(CASE WHEN detections.polarity = 'positive' THEN 1 ELSE 0 END)")
    tot_expr = Arel.sql("COUNT(*)")

    # -------------------------------------------------------------------------
    # Dotted comparison line (previous equal-length period):
    # Uses pre-computed rollups for speed (falls back to raw detections if unavailable)
    # -------------------------------------------------------------------------
    lookback_days = 29
    span_days     = (@range_end.to_date - @range_start.to_date).to_i + 1
    prev_start    = @range_start.to_date - span_days.days
    prev_end      = @range_start.to_date - 1.day

    lookback_start = prev_start - lookback_days.days
    lookback_end   = @range_end

    # Main sparkline uses rollups (fast)
    daily = fetch_daily_counts(start_date: lookback_start, end_date: lookback_end, metric_id: @metric.id)

    # Submetric/category queries still need raw scope (secondary, less critical)
    spark_scope =
      Detection
        .joins(message: :integration, signal_category: :submetric)
        .where(integrations: { workspace_id: wid })
        .where("messages.posted_at >= ? AND messages.posted_at <= ?", lookback_start.beginning_of_day, lookback_end.end_of_day)
        .merge(Detection.with_scoring_policy)
        .where(submetrics: { metric_id: @metric.id })

    spark_scope = apply_group_filter(spark_scope, @group_member_ids)

    anchors = spark_anchor_days(@range_start, @range_end)

    # Primary series (current range)
    series = rolling30_series(daily, @range_start, @range_end, anchors, reverse: @metric.reverse?)

    @spark_points = series[:points].map { |v| v.round }
    @spark_points = [@spark_points.first, @spark_points.first] if @spark_points.size < 2

    @gauge_value     = @spark_points.last.to_i
    @trend_delta     = (@spark_points.last.to_i - @spark_points.first.to_i)
    @trend_delta_abs = @trend_delta.abs.round(days <= 31 ? 1 : 0)

    label_fmt = days > 365 ? "%b %Y" : "%b %-d"
    @x_labels = anchors.map { |d| d.strftime(label_fmt) }

    # Comparison series (previous equal-length range), aligned to same x positions
    # We compute values at shifted anchor dates, then plot them at current x coords.
    @spark_points_compare = nil
    unless @is_all_time
      # Shift the comparison series by 1 day so the measured rolling-window endpoints
      # line up the way users intuitively expect across adjacent periods.
      #
      # Example (30-day view):
      # - blue left edge is the score ending on range_start
      # - grey right edge should be the score ending on range_start (i.e., shifted forward 1)
      shift_days = [span_days - 1, 0].max
      shifted_anchors = anchors.map { |d| d.to_date - shift_days.days }

      compare_series =
        rolling30_series(
          daily,
          prev_start + 1.day,
          prev_end + 1.day,
          shifted_anchors,
          reverse: @metric.reverse?
        )

      cmp = compare_series[:points].map { |v| v.round }
      @spark_points_compare = (cmp.size == @spark_points.size) ? cmp : nil
    end

    # Submetric mini sparklines: rolling 90 at the same anchors
    sub_ids = @metric.submetrics.pluck(:id)
    @submetric_spark_points = {}

    window_start_day = @range_end.to_date - 29.days
    window_end_day   = @range_end.to_date

    if sub_ids.any?
      daily_sub =
        spark_scope
          .group("submetrics.id", Arel.sql("DATE(messages.posted_at)"))
          .pluck("submetrics.id", Arel.sql("DATE(messages.posted_at)"), pos_expr, tot_expr)

      daily_by_sub = Hash.new { |h, k| h[k] = Hash.new { |hh, dd| hh[dd] = { pos: 0, tot: 0 } } }
      daily_sub.each do |sub_id, day, pos, tot|
        sid = sub_id.to_i
        d   = day.to_date
        daily_by_sub[sid][d][:pos] = pos.to_i
        daily_by_sub[sid][d][:tot] = tot.to_i
      end

      sub_ids.each do |sid|
        sseries = rolling30_series(daily_by_sub[sid], @range_start, @range_end, anchors, reverse: @metric.reverse?)
        pts = sseries[:points].map { |v| v.round }
        pts = [pts.first, pts.first] if pts.size < 2
        @submetric_spark_points[sid] = pts

        last30_total = 0
        (window_start_day..window_end_day).each do |dd|
          last30_total += daily_by_sub[sid][dd][:tot].to_i
        end
        @submetric_last30_counts[sid] = last30_total
        @submetric_detection_counts[sid] = last30_total  # Use last30 count, not full-range
        @submetric_rates[sid] = last30_total >= 3 ? pts.last.to_i : nil
      end
    end

    # Signal category scores: rolling 30 at end of selected range (counts remain full-range)
    if sub_ids.any?
      sc_ids = SignalCategory.where(submetric_id: sub_ids).pluck(:id)

      if sc_ids.any?
        daily_sc =
          spark_scope
            .group("signal_categories.id", Arel.sql("DATE(messages.posted_at)"))
            .pluck("signal_categories.id", Arel.sql("DATE(messages.posted_at)"), pos_expr, tot_expr)

        daily_by_sc = Hash.new { |h, k| h[k] = Hash.new { |hh, dd| hh[dd] = { pos: 0, tot: 0 } } }
        daily_sc.each do |sc_id, day, pos, tot|
          sid = sc_id.to_i
          d   = day.to_date
          daily_by_sc[sid][d][:pos] = pos.to_i
          daily_by_sc[sid][d][:tot] = tot.to_i
        end

        sc_ids.each do |sid|
          last30_total = 0
          (window_start_day..window_end_day).each do |dd|
            last30_total += daily_by_sc[sid][dd][:tot].to_i
          end
          @signal_category_detection_counts[sid] = last30_total  # Use last30 count, not full-range
          next if last30_total < 3  # Require minimum 3 detections (same as submetrics)

          sseries = rolling30_series(daily_by_sc[sid], @range_start, @range_end, [@range_end], reverse: @metric.reverse?)
          @signal_category_rates[sid] = sseries[:end_score].round
        end
      end
    end

    respond_to do |format|
      format.html

      format.json do
        render json: {
          gauge: render_to_string(
            partial: "dashboard/components/gauge",
            formats: [:html]
          ),
          last100: render_to_string(
            partial: "dashboard/components/signals",
            formats: [:html]
          ),
          metric_sparkline: render_to_string(
            partial: "dashboard/components/metric_sparkline",
            locals: {
              points:            @spark_points,
              comparison_points: @spark_points_compare, # dotted previous-period line
              x_labels:          @x_labels,
              y_title:           "Score",
              curve:             :smooth,
              curve_tension:     0.7,
              curve_pad_px:      8
            },
            formats: [:html]
          ),
          submetric_breakdown: render_to_string(
            partial: "dashboard/components/submetric_breakdown",
            locals: {
              metric:                           @metric,
              submetric_rates:                  @submetric_rates,
              submetric_detection_counts:       @submetric_detection_counts,
              submetric_last30_counts:          @submetric_last30_counts,
              signal_category_rates:            @signal_category_rates,
              signal_category_detection_counts: @signal_category_detection_counts,
              signal_category_debug_detections: @signal_category_debug_detections,
              submetric_spark_points:           @submetric_spark_points
            },
            formats: [:html]
          )
        }
      end
    end
  end




  # ====== NOT LUCAS / OTHER PAGES ======
  def not_lucas
    @onboarding = true
    @NOT_LUCAS_TAGLINES = [
      "Nice try, impostor.",
      "Say bye.",
      "Caught you snooping in the fridge.",
      "Breaking news: still no access.",
      "This is embarrassing for you.",
      "Lucas has 99 problems, and you are one of them.",
      "Demo privileges revoked.",
      "You’re in the penalty box until Lucas forgives you.",
      "nah.",
      "You’ve reached the exclusive Not VIP lounge.",
      "Please enjoy this handcrafted rejection.",
      "No entry. Them’s the rules.",
      "This page is like purgatory, but with worse fonts.",
      "You triggered the easter egg page.",
      "You were not consulted.",
      "Denied: Your ID badge is clearly fake.",
      "Stop right there.",
      "You’ve been quarantined.",
      "Think of this page as a velvet rope of shame.",
      "This is your fault.",
      "You unlocked rejection.",
      "You’re the 404.",
      "Redirecting to sadness.",
      "yeeted.",
      "Juuuuust a bit outside."
    ]
    @tagline = @NOT_LUCAS_TAGLINES.sample
  end

  def test
    @topbar_title = "Test"
  end

  def insights
    @topbar_title = "Insights"

    return unless @active_workspace

    group_ids = current_user_group_ids(@active_workspace)

    integration_user_ids =
      IntegrationUser
        .joins(:integration)
        .where(integrations: { workspace_id: @active_workspace.id })
        .where(user_id: current_user.id)
        .pluck(:id)

    user_scope = Insight.where(workspace_id: @active_workspace.id, subject_type: "User", subject_id: current_user.id)
    if integration_user_ids.any?
      user_scope = user_scope.or(
        Insight.where(workspace_id: @active_workspace.id, subject_type: "IntegrationUser", subject_id: integration_user_ids)
      )
    end
    group_scope  = group_ids.any? ? Insight.where(workspace_id: @active_workspace.id, subject_type: "Group", subject_id: group_ids) : Insight.none
    admin_scope  = workspace_admin? ? Insight.where(workspace_id: @active_workspace.id, subject_type: "Workspace", subject_id: @active_workspace.id) : Insight.none

    @insights = user_scope.or(group_scope).or(admin_scope)
                          .includes(:trigger_template, :metric, :subject, :driver_items)
                          .order(Arel.sql("COALESCE(window_end_at, created_at) DESC"))
                          .page(params[:page])
                          .per(15)

    lookups = build_driver_lookups(@insights)
    @insight_rows = @insights.map { |ins| present_insight(ins, lookups) }
  end

  # ====== RANDOM DETECTION FOR ONBOARDING SCROLLER ======
  def detections_random
    return render json: {} unless @active_workspace

    base_scope = Detection
      .joins(message: :integration)
      .where(integrations: { workspace_id: @active_workspace.id })
      .merge(Detection.with_scoring_policy)

    min_max = base_scope
      .pluck(Arel.sql("MIN(detections.logit_margin), MAX(detections.logit_margin)"))
      .first

    min_logit, max_logit = min_max
    return render json: {} if min_logit.nil? || max_logit.nil?

    det = base_scope
      .joins("INNER JOIN channels          ON channels.id = messages.channel_id")
      .joins("INNER JOIN signal_categories ON signal_categories.id = detections.signal_category_id")
      .joins("INNER JOIN submetrics        ON submetrics.id = signal_categories.submetric_id")
      .joins("INNER JOIN metrics           ON metrics.id = submetrics.metric_id")
      .order(Arel.sql("RANDOM()"))
      .limit(1)
      .select(
        "detections.id          AS det_id",
        "detections.score       AS det_score",
        "detections.polarity    AS det_polarity",
        "detections.logit_margin AS det_logit_margin",
        "messages.posted_at     AS msg_posted_at",
        "channels.name          AS channel_name",
        "channels.kind          AS channel_kind",
        "channels.is_private    AS channel_private",
        "metrics.name           AS metric_name",
        "metrics.reverse        AS metric_reverse",
        "signal_categories.name AS sc_name"
      )
      .first

    return render json: {} unless det

    channel_label =
      if det.channel_kind.to_s == "public_channel" && det.channel_name.present?
        "##{det.channel_name}"
      else
        "a private channel"
      end


    score        = det.det_score.to_i
    positive_raw = score >= 50
    positive     = det.metric_reverse ? !positive_raw : positive_raw
    dir_word     = positive ? "positive" : "negative"

    metric_name  = (det.metric_name || "").downcase
    sc_name      = (det.sc_name || "").downcase

    text = "Someone in #{channel_label} showed #{dir_word} signs of #{metric_name} related to #{sc_name} on #{det.msg_posted_at.in_time_zone('Eastern Time (US & Canada)').strftime('%b %-d %-I:%M%p %Z')}."

    ratio = det.det_logit_margin.to_f

    magnitude =
      if !min_logit || !max_logit || max_logit == min_logit
        3
      else
        norm = (ratio - min_logit) / (max_logit - min_logit)
        raw  = 1 + norm * 4
        m    = raw.round
        [[m, 1].max, 5].min
      end

    render json: {
      id:          det.det_id,
      metric_key:  det.metric_name.to_s.parameterize,
      positive:    positive,
      text:        text,
      channel:     det.channel_private ? nil : det.channel_name,
      posted_at:   det.msg_posted_at,
      created_at:  nil,
      logit_margin: ratio,
      magnitude:   magnitude
    }
  end


  # ====== ETA ESTIMATOR (velocity-based with smoothing) ======
  def analyze_estimate
    ws = @active_workspace
    return render(json: { ok: false, error: "No active workspace" }, status: :unprocessable_entity) unless ws

    wid = ws.id
    now = Time.current
    rid = request.request_id
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    analyzer_log(:start, ws: wid, rid: rid)

    # ----------------------------------------
    # Get actual message counts (not timestamp-based)
    # ----------------------------------------
    measured_group  = ws.groups.first
    measured_iu_ids = measured_group&.integration_user_ids || []
    people_count    = measured_iu_ids.size

    max_days_analyzed   = Integration.where(workspace_id: wid).maximum(:days_analyzed).to_i
    any_analyze_complete = Integration.where(workspace_id: wid, analyze_complete: true).exists?
    dashboard_ready = any_analyze_complete || max_days_analyzed >= 30

    analyzer_log(:people_scope, ws: wid, rid: rid, people_count: people_count, days_analyzed: max_days_analyzed, analyze_complete: any_analyze_complete, dashboard_ready: dashboard_ready)

    # Early exit if no people
    if people_count == 0
      return render json: {
        ok: true,
        dashboard_ready: dashboard_ready,
        people_count: 0,
        eta_seconds: 0,
        phase: "complete",
        progress_pct: 100,
        sampled_at: now.iso8601
      }
    end

    cutoff = 59.days.ago

    # Total messages ingested in the 60-day window (from measured users)
    messages_ingested = Message
      .joins(:integration)
      .where(integrations: { workspace_id: wid })
      .where(integration_user_id: measured_iu_ids)
      .where("messages.posted_at >= ?", cutoff)
      .count

    # Messages that have been processed (inference complete)
    messages_processed = Message
      .joins(:integration)
      .where(integrations: { workspace_id: wid })
      .where(integration_user_id: measured_iu_ids)
      .where("messages.posted_at >= ?", cutoff)
      .where.not(processed_at: nil)
      .count

    analyzer_log(:message_counts, ws: wid, rid: rid, ingested: messages_ingested, processed: messages_processed, cutoff: cutoff.iso8601)

    # Check if ingestion is still running.
    # Slack marks backfill_complete; Teams has a Phase A (30d) notion via backfill pointers.
    teams_integrations = Integration.where(workspace_id: wid, kind: "microsoft_teams")
    slack_integrations = Integration.where(workspace_id: wid, kind: "slack")

    seconds_60d = 60.days.to_i
    slack_channels_incomplete = Channel
      .joins(:integration)
      .where(integrations: { workspace_id: wid, kind: "slack" })
      .where(is_archived: false)
      .where(history_unreachable: [false, nil])
      .where("last_history_status IS NULL OR last_history_status NOT IN (?)", ["error", "unreachable"])
      .where(<<~SQL.squish, seconds_60d: seconds_60d)
        (
          backfill_anchor_latest_ts IS NULL
          OR backfill_next_oldest_ts IS NULL
          OR backfill_next_oldest_ts > GREATEST(
            backfill_anchor_latest_ts - :seconds_60d,
            COALESCE(created_unix, 0)
          )
        )
      SQL
      .count

    teams_channels_30d_incomplete = 0
    if teams_integrations.exists?
      seconds_60d = 60.days.to_i
      teams_channels_30d_incomplete = Channel
        .joins(:integration)
        .where(integrations: { workspace_id: wid, kind: "microsoft_teams" })
        .where(is_archived: false)
        .where(history_unreachable: [false, nil])
        .where(kind: %w[public_channel private_channel])
        .where(<<~SQL.squish, seconds_60d: seconds_60d)
          (
            backfill_anchor_latest_ts IS NULL
            OR backfill_next_oldest_ts IS NULL
            OR backfill_next_oldest_ts > (backfill_anchor_latest_ts - :seconds_60d)
          )
        SQL
        .count
    end

    ingestion_complete = (slack_channels_incomplete == 0) && (teams_channels_30d_incomplete == 0)

    analyzer_log(
      :ingestion_state,
      ws: wid,
      rid: rid,
      slack_channels_incomplete: slack_channels_incomplete,
      teams_channels_30d_incomplete: teams_channels_30d_incomplete,
      ingestion_complete: ingestion_complete
    )

    # ----------------------------------------
    # Total expected messages (30-day window)
    # ----------------------------------------

    # Slack: keep existing search-derived denominator (do NOT break Slack)
    slack_channel_scope = Channel
      .joins(:integration)
      .where(integrations: { workspace_id: wid, kind: "slack" })
      .where(is_archived: false)

    slack_channels_total = slack_channel_scope.count
    slack_channels_with_estimate = slack_channel_scope.where.not(estimated_message_count: nil).count

    slack_estimated_from_search = slack_channel_scope
      .where.not(estimated_message_count: nil)
      .sum(:estimated_message_count)
      .to_i

    slack_expected = 0
    if slack_estimated_from_search.to_i > 0
      slack_expected = slack_estimated_from_search
    end

    # Teams: use reports (channel volume) when available + a conservative chat estimate.
    teams_channel_scope = Channel
      .joins(:integration)
      .where(integrations: { workspace_id: wid, kind: "microsoft_teams" })
      .where(is_archived: false)
      .where(history_unreachable: [false, nil])
      .where(kind: %w[public_channel private_channel])

    teams_channels_total = teams_channel_scope.count
    # 30-day readiness (not deep backfill_complete): aligns analyzer UX to 30d onboarding goals.
    teams_channels_backfilled = teams_channel_scope
      .where(<<~SQL.squish, seconds_60d: 60.days.to_i)
        (
          backfill_anchor_latest_ts IS NOT NULL
          AND backfill_next_oldest_ts IS NOT NULL
          AND backfill_next_oldest_ts <= (backfill_anchor_latest_ts - :seconds_60d)
        )
      SQL
      .count
    teams_report_state = session["teams_report_state_#{wid}"] || {}

    teams_chat_state = {}
    teams_expected = 0
    if teams_integrations.exists?
      report_total = teams_report_channel_messages_30d_total(ws: ws)
      teams_report_state = session["teams_report_state_#{wid}"] || {}

      # Chats aren't in reports. Model 30d chat volume progressively across 7 day-slices
      # so the UI can show dynamic x/y feedback while estimate is being prepared.
      chat_model = teams_chat_estimate_30d_progressive(ws: ws)
      teams_chat_state = chat_model[:state] || {}
      chats_est_30d = chat_model[:estimate_30d].to_i

      teams_expected = report_total.to_i + chats_est_30d.to_i
    end

    total_expected = slack_expected.to_i + teams_expected.to_i
    total_expected_available = (slack_expected.to_i > 0) || (teams_expected.to_i > 0)

    # Never allow denominator < what we've already ingested.
    total_expected = [total_expected, messages_ingested].max

    # Fallback if no estimator available yet.
    total_expected = [messages_ingested * 2, 100].max unless total_expected_available

    # If ingestion is still running, pad the denominator so we don't hit 100% early.
    total_expected = (messages_ingested * 1.1).ceil if !ingestion_complete && messages_ingested > total_expected

    inference_pct = total_expected > 0 ? (messages_processed.to_f / total_expected).clamp(0.0, 1.0) : 0.0

    analyzer_log(
      :expected_model,
      ws: wid,
      rid: rid,
      slack_expected: slack_expected,
      teams_expected: teams_expected,
      total_expected: total_expected,
      total_expected_available: total_expected_available,
      slack_channels_total: slack_channels_total,
      slack_channels_with_estimate: slack_channels_with_estimate,
      teams_channels_total: teams_channels_total,
      teams_channels_backfilled: teams_channels_backfilled,
      teams_report_phase: teams_report_state["phase"],
      teams_chat_phase: teams_chat_state["phase"]
    )

    # ----------------------------------------
    # Determine phase (based on actual state, not estimates)
    # ----------------------------------------
    # Keep phase aligned with dashboard visibility logic so UI doesn't flap "Done" while
    # right panel still renders analyze mode (which is keyed off 30-day readiness).
    phase = if !ingestion_complete
      "importing_analyzing"
    elsif messages_processed < messages_ingested
      "finishing"
    elsif dashboard_ready
      "complete"
    else
      "finishing"
    end

    # ----------------------------------------
    # Calculate progress percentage
    # ----------------------------------------
    if phase == "complete"
      progress_pct = 100.0
    elsif phase == "finishing"
      # Ingestion done, inference catching up: 80-100%
      tail_pct = messages_ingested > 0 ? (messages_processed.to_f / messages_ingested).clamp(0.0, 1.0) : 1.0
      progress_pct = 80.0 + (tail_pct * 20.0)
    else
      # Both running: 0-80% based on inference progress
      progress_pct = (inference_pct * 80.0)
    end

    analyzer_log(:phase_decision, ws: wid, rid: rid, phase: phase, progress_pct: progress_pct.round(2), inference_pct: inference_pct.round(4))

    # ----------------------------------------
    # Phase timing + detailed telemetry
    # ----------------------------------------
    phase_cache_key = "analyze_phase_state_#{wid}"
    phase_state = Rails.cache.read(phase_cache_key) || {}
    prev_phase = phase_state["phase"]
    prev_started_at = phase_state["started_at"]

    if prev_phase != phase
      if prev_phase && prev_started_at
        duration_s = (now.to_f - prev_started_at.to_f).round(1)
        analyzer_log(
          :phase_duration,
          ws: wid,
          rid: rid,
          phase: prev_phase,
          duration_s: duration_s,
          ingested: messages_ingested,
          processed: messages_processed,
          people_count: people_count,
          dashboard_ready: dashboard_ready
        )
      end

      phase_state = { "phase" => phase, "started_at" => now.to_f }
      Rails.cache.write(phase_cache_key, phase_state, expires_in: 2.hours)

      analyzer_log(
        :phase_start,
        ws: wid,
        rid: rid,
        phase: phase,
        ingested: messages_ingested,
        processed: messages_processed,
        expected: total_expected,
        ingestion_complete: ingestion_complete,
        slack_channels_incomplete: slack_channels_incomplete,
        teams_channels_30d_incomplete: teams_channels_30d_incomplete,
        people_count: people_count
      )
    end

    # ----------------------------------------
    # Velocity calculation (from session snapshots)
    # ----------------------------------------
    session_key = "analyze_snapshots_#{wid}"
    snapshots = session[session_key] || []

    # Current snapshot
    current_snapshot = {
      "at" => now.to_f,
      "ingested" => messages_ingested,
      "processed" => messages_processed,
      "phase" => phase
    }

    # Keep last 5 snapshots (roughly 30 seconds of history at 6s polling)
    snapshots = snapshots.last(4) + [current_snapshot]
    session[session_key] = snapshots

    # Need at least 2 snapshots to calculate velocity
    velocity = nil
    eta_seconds = nil

    if snapshots.size >= 2
      oldest = snapshots.first
      newest = snapshots.last
      time_delta = newest["at"] - oldest["at"]

      if time_delta > 5.0 # At least 5 seconds between samples
        # Velocity = messages processed per second (inference bottleneck)
        msg_delta = newest["processed"] - oldest["processed"]
        velocity = msg_delta / time_delta if time_delta > 0

        # During finishing phase, remaining is based on actual ingested count (known).
        # During importing phase, use total_expected (which includes headroom).
        remaining = if ingestion_complete
          messages_ingested - messages_processed
        else
          total_expected - messages_processed
        end
        eta_seconds = velocity && velocity > 0 ? (remaining / velocity).ceil : nil
      end
    end

    # ----------------------------------------
    # Smoothing: prevent wild jumps
    # ----------------------------------------
    prev_eta_key = "analyze_prev_eta_#{wid}"
    prev_eta = session[prev_eta_key]

    if eta_seconds && prev_eta && prev_eta > 0
      # Exponential smoothing: 70% previous, 30% new
      smoothed_eta = (0.7 * prev_eta + 0.3 * eta_seconds).ceil

      # Clamp: don't let ETA increase by more than 20%
      max_increase = (prev_eta * 1.2).ceil
      smoothed_eta = [smoothed_eta, max_increase].min

      # Floor: at least 10 seconds if not complete
      smoothed_eta = [smoothed_eta, 10].max unless phase == "complete"

      eta_seconds = smoothed_eta
    end

    # Store for next poll
    session[prev_eta_key] = eta_seconds if eta_seconds

    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
    analyzer_log(:eta, ws: wid, rid: rid, eta_seconds: eta_seconds, velocity: velocity&.round(4), snapshots: snapshots.size, elapsed_ms: elapsed_ms)

    # ----------------------------------------
    # Response
    # ----------------------------------------

    analyzer_log(
      :response,
      ws: wid,
      rid: rid,
      phase: phase,
      progress_pct: progress_pct.round(1),
      eta_seconds: eta_seconds,
      ingestion_complete: ingestion_complete,
      dashboard_ready: dashboard_ready,
      elapsed_ms: elapsed_ms
    )

    render json: {
      ok: true,
      dashboard_ready: dashboard_ready,
      people_count: people_count,

      # Primary outputs
      phase: phase,
      progress_pct: progress_pct.round(1),
      eta_seconds: eta_seconds,
      eta_calculating: (snapshots.size < 2) || !total_expected_available,

      # Debug / breakdown
      messages_ingested: messages_ingested,
      messages_processed: messages_processed,
      ingestion_complete: ingestion_complete,
      total_expected: total_expected,
      total_expected_available: total_expected_available,
      slack_channels_total: slack_channels_total,
      slack_channels_with_estimate: slack_channels_with_estimate,
      slack_channels_pending_estimate: [slack_channels_total - slack_channels_with_estimate, 0].max,
      teams_channels_total: teams_channels_total,
      teams_channels_backfilled: teams_channels_backfilled,
      teams_channels_pending_backfill: [teams_channels_total - teams_channels_backfilled, 0].max,
      teams_report_phase: teams_report_state["phase"],
      teams_report_done: teams_report_state["done"],
      teams_report_total: teams_report_state["total"],
      teams_chat_model_phase: teams_chat_state["phase"],
      teams_chat_model_done: teams_chat_state["done"],
      teams_chat_model_total: teams_chat_state["total"],
      velocity: velocity&.round(2),
      snapshots_count: snapshots.size,

      days_analyzed: max_days_analyzed,
      any_analyze_complete: any_analyze_complete,
      sampled_at: now.iso8601
    }
  rescue => e
    analyzer_log(:failed, ws: @active_workspace&.id, rid: request.request_id, error_class: e.class.name, error: e.message)
    render json: { ok: false, error: "estimate_failed" }, status: :unprocessable_entity
  end

  # ------------------------------
  # Teams helpers (estimation only)
  # ------------------------------

  def teams_report_channel_messages_30d_total(ws:)
    wid = ws.id
    cache_key = "teams_report_total_#{wid}"
    cache_at_key = "teams_report_total_at_#{wid}"
    state_key = "teams_report_state_#{wid}"

    cached = session[cache_key]
    cached_at = session[cache_at_key]

    if cached.present? && cached_at.present?
      begin
        age = Time.current.to_f - cached_at.to_f
        if age < 10.minutes.to_i
          session[state_key] = { "phase" => "done", "done" => 1, "total" => 1 }
          analyzer_log(:teams_report_cache_hit, ws: wid, age_s: age.round(1), total: cached.to_i)
          return cached.to_i
        end
      rescue
        # ignore
      end
    end

    integration = Integration.find_by(workspace_id: wid, kind: "microsoft_teams")
    unless integration
      session[state_key] = { "phase" => "idle", "done" => 0, "total" => 1 }
      analyzer_log(:teams_report_idle, ws: wid, reason: "no_integration")
      return 0
    end

    iu = integration.installer_integration_user
    unless iu
      session[state_key] = { "phase" => "idle", "done" => 0, "total" => 1 }
      analyzer_log(:teams_report_idle, ws: wid, integration_id: integration.id, reason: "no_installer_user")
      return 0
    end

    token = integration.ensure_ms_access_token!(iu) rescue nil
    if token.blank?
      session[state_key] = { "phase" => "idle", "done" => 0, "total" => 1 }
      analyzer_log(:teams_report_idle, ws: wid, integration_id: integration.id, reason: "no_token")
      return 0
    end

    # 1) Identify teams the installer user is joined to
    joined_team_ids = []
    begin
      res = Faraday.get("https://graph.microsoft.com/v1.0/me/joinedTeams") do |req|
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["Accept"] = "application/json"
      end
      if res.status.to_i >= 200 && res.status.to_i < 300
        body = JSON.parse(res.body) rescue {}
        joined_team_ids = Array(body["value"]).map { |t| t["id"].to_s }.reject(&:blank?)
      end
    rescue
      joined_team_ids = []
    end

    analyzer_log(:teams_report_joined_teams, ws: wid, integration_id: integration.id, joined_teams: joined_team_ids.size)
    # 2) Pull tenant report (CSV) and sum channel+reply messages for joined teams
    total = 0
    session[state_key] = { "phase" => "fetching_reports", "done" => 0, "total" => 1 }
    begin
      url = "https://graph.microsoft.com/v1.0/reports/getTeamsTeamActivityDetail(period='D30')"
      res = Faraday.get(url) do |req|
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["Accept"] = "text/csv"
      end

      if res.status.to_i >= 200 && res.status.to_i < 300
        require "csv"
        csv = res.body.to_s

        first_headers = nil
        CSV.parse(csv, headers: true) do |row|
          first_headers ||= row.headers
          
          team_id = row["Team Id"].to_s
          next if joined_team_ids.any? && !joined_team_ids.include?(team_id)

          channel_count = row["Channel messages"].to_i
          reply_count   = row["Reply messages"].to_i

          # Some tenants use different header casing; be defensive.
          if channel_count == 0 && row.headers.include?("channelMessageCount")
            channel_count = row["channelMessageCount"].to_i
          end
          if reply_count == 0 && row.headers.include?("replyMessageCount")
            reply_count = row["replyMessageCount"].to_i
          end

          total += channel_count + reply_count
        end
      end
    rescue
      total = 0
    end

    analyzer_log(:teams_report_done, ws: wid, integration_id: integration.id, report_total: total)
    session[cache_key] = total
    session[cache_at_key] = Time.current.to_f
    session[state_key] = { "phase" => "done", "done" => 1, "total" => 1 }
    total
  end

  def teams_chat_estimate_30d_progressive(ws:)
    wid = ws.id
    state_key = "teams_chat_model_state_#{wid}"
    cache_key = "teams_chat_model_estimate_#{wid}"
    cache_at_key = "teams_chat_model_estimate_at_#{wid}"

    cached = session[cache_key]
    cached_at = session[cache_at_key]
    if cached.present? && cached_at.present?
      age = Time.current.to_f - cached_at.to_f rescue 9_999_999
      if age < 10.minutes.to_i
        state = { "phase" => "done", "done" => 7, "total" => 7 }
        session[state_key] = state
        analyzer_log(:teams_chat_model_cache_hit, ws: wid, age_s: age.round(1), estimate_30d: cached.to_i)
        return { estimate_30d: cached.to_i, state: state }
      end
    end

    state = (session[state_key] || {}).dup
    total_slices = 7

    unless state["phase"] == "modeling" || state["phase"] == "done"
      state = {
        "phase" => "modeling",
        "done" => 0,
        "total" => total_slices,
        "sum" => 0,
        "start_day" => 6.days.ago.to_date.iso8601
      }
    end

    if state["phase"] == "done"
      est = session[cache_key].to_i
      return { estimate_30d: est, state: state }
    end

    done = state["done"].to_i
    sum = state["sum"].to_i

    if done < total_slices
      day = (6.days.ago.to_date + done.days)
      day_start = day.beginning_of_day
      day_end = day.end_of_day

      teams_iu_ids = IntegrationUser.joins(:integration)
        .where(integrations: { workspace_id: wid, kind: "microsoft_teams" })
        .pluck(:id)

      day_count = Message
        .joins(:integration, :channel)
        .where(integrations: { workspace_id: wid, kind: "microsoft_teams" })
        .where(integration_user_id: teams_iu_ids)
        .where(channels: { kind: %w[im mpim] })
        .where("messages.posted_at >= ? AND messages.posted_at <= ?", day_start, day_end)
        .count

      sum += day_count.to_i
      done += 1

      analyzer_log(:teams_chat_model_slice, ws: wid, day: day.iso8601, day_count: day_count.to_i, done: done, total: total_slices)

      state["done"] = done
      state["sum"] = sum
      state["total"] = total_slices
      state["phase"] = done >= total_slices ? "done" : "modeling"
      session[state_key] = state
    end

    sample_days = [state["done"].to_i, 1].max
    chats_est_30d = ((state["sum"].to_f / sample_days.to_f) * 30.0)
    chats_est_30d = (chats_est_30d * 1.4).ceil

    if state["phase"] == "done"
      session[cache_key] = chats_est_30d
      session[cache_at_key] = Time.current.to_f
      analyzer_log(:teams_chat_model_done, ws: wid, estimate_30d: chats_est_30d)
    end

    { estimate_30d: chats_est_30d, state: state }
  end

  # app/controllers/dashboard_controller.rb
  def detections_stats
    ws = @active_workspace
    return render(json: { ok: false, error: "No active workspace" }, status: :unprocessable_entity) unless ws

    wid = ws.id
    cutoff = 59.days.ago

    measured_group  = ws.groups.first
    measured_iu_ids = measured_group&.integration_user_ids || []
    people_count    = measured_iu_ids.size

    base_messages =
      Message
        .joins(:integration)
        .where(integrations: { workspace_id: wid })
        .where("messages.posted_at >= ?", cutoff)

    # Filter to measured people if present
    if measured_iu_ids.any?
      base_messages = base_messages.where(integration_user_id: measured_iu_ids)
    end

    # "Ingested" = messages discovered in window (whether processed yet or not)
    messages_ingested = base_messages.count

    # "Scanned/processed" = terminal (processed_at set)
    messages_scanned =
      base_messages
        .where.not(processed_at: nil)
        .count

    base_detections =
      Detection
        .joins(message: :integration)
        .where(integrations: { workspace_id: wid })
        .where("messages.posted_at >= ?", cutoff)
        .merge(Detection.with_scoring_policy)

    if measured_iu_ids.any?
      base_detections = base_detections.where(messages: { integration_user_id: measured_iu_ids })
    end

    signals_found = base_detections.count

    days_analyzed =
      Integration.where(workspace_id: wid).maximum(:days_analyzed).to_i

    render json: {
      ok: true,
      people_count: people_count,
      messages_ingested: messages_ingested,
      messages_scanned: messages_scanned,
      signals_found: signals_found,
      days_analyzed: days_analyzed
    }
  rescue => e
    Rails.logger.warn "[DetectionsStats] failed ws_id=#{ws&.id}: #{e.class}: #{e.message}"
    render json: { ok: false, error: "stats_failed" }, status: :unprocessable_entity
  end






  def docs
  end

  def workspace_pending
    @topbar_title = "Workspace not ready"
  end


  private

  def analyzer_verbose_logging?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("ANALYZER_FLOW_VERBOSE", "true"))
  rescue
    true
  end

  def analyzer_log(stage, attrs = {})
    return unless analyzer_verbose_logging?

    flat = attrs.compact.transform_values { |v| v.is_a?(Time) ? v.iso8601 : v }
    payload = flat.map { |k, v| "#{k}=#{v}" }.join(" ")
    Rails.logger.info("[AnalyzerFlow] stage=#{stage} #{payload}".strip)
  rescue
    nil
  end

  def build_driver_lookups(insights)
    ids_by_type = Hash.new { |h, k| h[k] = [] }

    insights.each do |ins|
      ins.driver_items.each do |di|
        ids_by_type[di.driver_type] << di.driver_id if di.driver_id
      end
    end

    {
      "Metric"         => Metric.where(id: ids_by_type["Metric"].uniq).index_by(&:id),
      "Submetric"      => Submetric.where(id: ids_by_type["Submetric"].uniq).index_by(&:id),
      "SignalCategory" => SignalCategory.where(id: ids_by_type["SignalCategory"].uniq).index_by(&:id)
    }
  end

  def present_insight(insight, lookups)
    {
      id: insight.id,
      title: insight.summary_title.presence || fallback_title(insight),
      body: insight.summary_body.presence || "(Summary pending)",
      labels: driver_labels_for(insight, lookups),
      trigger_label: trigger_label(insight),
      trigger_icon: trigger_icon(insight),
      recipient_label: recipient_label(insight),
      recipients: recipients_for(insight),
      sent_at: insight_timestamp(insight)
    }
  end

  def insight_stats(insight)
    payload = insight.data_payload
    return {} unless payload.is_a?(Hash)

    stats = payload.respond_to?(:with_indifferent_access) ? payload.with_indifferent_access[:stats] : payload[:stats]
    if stats && !stats.is_a?(Hash)
      stats = stats.to_unsafe_h if stats.respond_to?(:to_unsafe_h)
      stats = stats.to_h if !stats.is_a?(Hash) && stats.respond_to?(:to_h)
    end
    stats.is_a?(Hash) ? stats.with_indifferent_access : {}
  end

  def driver_labels_for(insight, lookups)
    labels = []
    metric_label = insight.metric&.name
    labels << { text: metric_label, type: :metric, icon: metric_icon_slug(metric_label) } if metric_label.present?

    drivers = insight.driver_items.select do |di|
      %w[Metric Submetric SignalCategory].include?(di.driver_type)
    end

    drivers = drivers.reject do |di|
      di.driver_type == "Metric" && insight.metric_id.present? && di.driver_id == insight.metric_id
    end

    weights = drivers.map { |di| di.weight.to_f }.reject(&:zero?)
    return labels.presence || [fallback_title(insight)] if weights.empty?

    max_w = weights.max
    threshold = [0.15, max_w * 0.5].max

    drivers
      .select { |di| di.weight.to_f >= threshold }
      .sort_by { |di| -di.weight.to_f }
      .first(3)
      .each do |di|
        lbl = driver_label_entry(di, lookups)
        labels << lbl if lbl.present?
      end

    labels.presence || [{ text: fallback_title(insight), type: :generic }]
  end

  def driver_label_entry(driver_item, lookups)
    case driver_item.driver_type
    when "Metric"
      name = lookups["Metric"][driver_item.driver_id]&.name
      name ? { text: name, type: :metric, icon: metric_icon_slug(name) } : nil
    when "Submetric"
      name = lookups["Submetric"][driver_item.driver_id]&.name
      name ? { text: name, type: :submetric } : nil
    when "SignalCategory"
      name = lookups["SignalCategory"][driver_item.driver_id]&.name
      name ? { text: name, type: :category } : nil
    else
      nil
    end
  end

  def trigger_label(insight)
    insight.trigger_template&.name.presence || insight.kind.to_s.titleize
  end

  def trigger_icon(insight)
    dir = insight.trigger_template&.direction || insight.polarity

    case dir
    when "positive" then "arrow-up-circle"
    when "negative" then "arrow-down-circle"
    else "doc"
    end
  end

  def scope_label(insight)
    case insight.subject_type.to_s
    when "User", "IntegrationUser"
      "Personal"
    when "Group"
      "Group"
    else
      insight.kind.to_s == "exec_summary" ? "Executive summary" : "Workspace"
    end
  end

  def scope_kind(insight)
    case insight.subject_type.to_s
    when "User", "IntegrationUser"
      "personal"
    when "Group"
      "group"
    else
      insight.kind.to_s == "exec_summary" ? "executive" : "workspace"
    end
  end

  def recipient_label(insight)
    case insight.subject
    when User
      "You"
    when IntegrationUser
      "You"
    when Group
      insight.subject.name
    else
      "Workspace"
    end
  end

  def window_label(insight)
    start_at = insight.window_start_at
    end_at = insight.window_end_at
    return nil unless start_at || end_at

    start_at ||= end_at
    end_at ||= start_at

    start_date = start_at.in_time_zone.to_date
    end_date = end_at.in_time_zone.to_date
    current_year = Time.zone.today.year

    if start_date == end_date
      fmt = start_date.year == current_year ? "%b %-d" : "%b %-d, %Y"
      return start_date.strftime(fmt)
    end

    start_fmt = start_date.year == end_date.year ? "%b %-d" : "%b %-d, %Y"
    end_fmt = end_date.year == current_year ? "%b %-d" : "%b %-d, %Y"
    "#{start_date.strftime(start_fmt)} – #{end_date.strftime(end_fmt)}"
  end

  def insight_timestamp(insight)
    insight.delivered_at || insight.created_at
  end

  def can_view_insight?(insight)
    return false unless @active_workspace
    return false unless insight.workspace_id == @active_workspace.id

    case insight.subject_type.to_s
    when "User"
      insight.subject_id == current_user.id
    when "Group"
      group_ids = current_user_group_ids(@active_workspace)
      group_ids.include?(insight.subject_id)
    when "Workspace"
      workspace_admin?
    else
      false
    end
  end

  def fallback_title(insight)
    insight.metric&.name || insight.trigger_template&.name || "Insight"
  end

  def metric_icon_slug(name)
    return nil unless name.present?
    name.to_s.parameterize
  end

  def recipients_for(insight)
    members = Array(insight.affected_members)
    if members.present?
      recs = recipients_from_member_snapshots(insight, members)
      return recs if recs.any?
    end

    recipients_from_deliveries(insight)
  end

  def workspace_user_index(workspace)
    @workspace_user_cache ||= {}
    @workspace_user_cache[workspace.id] ||= workspace.workspace_users.includes(:user).index_by(&:user_id)
  end

  def recipients_from_member_snapshots(insight, members)
    member_user_ids = members.filter_map { |m| m.respond_to?(:[]) ? (m[:user_id] || m["user_id"]) : nil }.compact
    member_iu_ids   = members.filter_map { |m| m.respond_to?(:[]) ? (m[:integration_user_id] || m["integration_user_id"]) : nil }.compact

    users = member_user_ids.any? ? User.where(id: member_user_ids).index_by(&:id) : {}
    integration_users = member_iu_ids.any? ? IntegrationUser.where(id: member_iu_ids).index_by(&:id) : {}
    ws_users = workspace_user_index(insight.workspace)

    seen = {}

    members.filter_map do |raw|
      member = raw.respond_to?(:with_indifferent_access) ? raw.with_indifferent_access : raw
      next unless member.respond_to?(:[])

      user = users[member[:user_id]]
      iu   = integration_users[member[:integration_user_id]]

      name = member[:name].presence ||
             user_display_name(user) ||
             integration_user_display_name(iu) ||
             member[:email].presence
      next unless name.present?

      key = [member[:user_id], member[:integration_user_id], name]
      next if seen[key]
      seen[key] = true

      {
        name: name,
        avatar_url: avatar_for_member(ws_users, user, iu)
      }
    end
  end

  def recipients_from_deliveries(insight)
    deliveries = insight.deliveries.includes(:user).to_a
    users = deliveries.map(&:user).compact.uniq

    subject = insight.subject

    if users.empty?
      case subject
      when User
        users << subject
      when IntegrationUser
        if subject.user
          users << subject.user
        else
          return [{
            name: integration_user_display_name(subject),
            avatar_url: subject.avatar_url
          }].compact
        end
      when Group
        users.concat(subject.integration_users.includes(:user).map(&:user).compact)
      when Workspace
        admins = insight.workspace.workspace_users.includes(:user).select do |wu|
          wu.is_owner? || wu.role.to_s == "owner" || wu.role.to_s == "admin"
        end
        users.concat(admins.map(&:user).compact)
      end
    end

    ws_users = workspace_user_index(insight.workspace)

    users.uniq.map do |u|
      {
        name: user_display_name(u),
        avatar_url: ws_users[u.id]&.avatar_url_for_workspace
      }
    end
  end

  def user_display_name(user)
    return nil unless user
    user.full_name.presence || user.name.presence || user.email
  end

  def integration_user_display_name(integration_user)
    return nil unless integration_user
    integration_user.real_name.presence || integration_user.display_name.presence || integration_user.email
  end

  def avatar_for_member(ws_users, user, integration_user)
    if user && ws_users[user.id]
      ws_users[user.id].avatar_url_for_workspace
    else
      integration_user&.avatar_url
    end
  end

  def load_topbar_groups
    return unless @active_workspace

    everyone_group = @active_workspace.groups.order(:created_at).find_by(name: "Everyone")

    # Only include groups that meet the anonymity threshold (>= 3 members).
    @topbar_groups =
      @active_workspace.groups
        .left_joins(:group_members)
        .group("groups.id")
        .having("COUNT(DISTINCT group_members.integration_user_id) >= 3")
        .order(:name)

    group_param = params[:group_id].presence || @current_group_id

    # Normalize old "all" → real Everyone group if present
    if group_param == "all" && everyone_group
      group_param = "group:#{everyone_group.id}"
    end

    # Check if everyone_group meets privacy floor (>= 3 members)
    everyone_meets_floor = everyone_group && everyone_group.integration_user_ids.size >= 3

    if group_param.present?
      gid =
        if group_param.to_s.start_with?("group:")
          group_param.to_s.split(":", 2)[1]
        else
          group_param
        end

      # If selected group is <3, it won't be in @topbar_groups, so this returns nil.
      @selected_group = @topbar_groups.find_by(id: gid)

      # Fallback to Everyone only if it meets privacy floor (>= 3 members).
      @selected_group ||= everyone_group if everyone_meets_floor
    elsif everyone_meets_floor
      @selected_group = everyone_group
    end

    if @selected_group
      @group_member_ids = @selected_group.integration_user_ids
      @group_scope      = "group:#{@selected_group.id}"
    else
      # Fallback (no groups yet)
      @group_member_ids = nil
      @group_scope      = "all"
    end
  end



  def apply_group_filter(scope, member_ids)
    return scope unless member_ids
    return scope.none if member_ids.empty?

    scope.where(messages: { integration_user_id: member_ids })
  end

  def set_persistent_group
    if params[:group_id].present?
      session[:dash_group_id] = params[:group_id]
    end

    @current_group_id = session[:dash_group_id].presence || "all"
  end

  def set_persistent_range
    fmt = "%Y-%m-%d"

    today         = Time.zone.today
    default_start = 29.days.ago.to_date
    default_end   = today

    all_time_sentinel = Date.new(2000, 1, 1)

    # ---------------------------------------------------------------------------
    # Persist requested range into session (if provided)
    # ---------------------------------------------------------------------------

    # Preferred: preset-based selection (rolling ranges stay rolling)
    if params[:preset].present?
      preset = params[:preset].to_s
      session[:dash_range_preset] = preset

      # If they explicitly choose a preset, clear any previously-persisted hard dates.
      session.delete(:dash_range_start)
      session.delete(:dash_range_end)

      # Track whether the user explicitly selected "all time"
      session[:dash_is_all_time] = (preset == "all_time")

    # Fallback: explicit dates (custom / legacy)
    elsif params[:start].present? && params[:end].present?
      begin
        start_param = Date.strptime(params[:start], fmt)
        end_param   = Date.strptime(params[:end],   fmt)

        # normalize ordering
        if end_param < start_param
          start_param, end_param = end_param, start_param
        end

        session[:dash_range_preset] = nil
        session[:dash_range_start]  = start_param.to_s
        session[:dash_range_end]    = end_param.to_s

        # Track whether the user explicitly selected "all time"
        session[:dash_is_all_time] = (start_param == all_time_sentinel)
      rescue ArgumentError
        # ignore bad inputs; fall back to session/default
      end
    end

    # Default if never set
    session[:dash_is_all_time] = false if session[:dash_is_all_time].nil?

    @range_preset = session[:dash_range_preset].presence

    # ---------------------------------------------------------------------------
    # Resolve range from preset (preferred), session hard-dates, or defaults
    # ---------------------------------------------------------------------------

    if @range_preset.present?
      case @range_preset
      when "last_30"
        @range_start = (today - 29.days)
        @range_end   = today
      when "last_60"
        @range_start = (today - 59.days)
        @range_end   = today
      when "last_90"
        @range_start = (today - 89.days)
        @range_end   = today
      when "last_quarter"
        this_q_start = today.beginning_of_quarter
        last_q_end   = this_q_start - 1.day
        @range_start = last_q_end.beginning_of_quarter
        @range_end   = last_q_end
      when "last_year"
        last_year_end   = today.beginning_of_year - 1.day
        @range_start    = last_year_end.beginning_of_year
        @range_end      = last_year_end
      when "ytd"
        @range_start = today.beginning_of_year
        @range_end   = today
      when "all_time"
        @range_start = all_time_sentinel
        @range_end   = today
      else
        # unknown preset → fall back
        @range_preset = nil
      end
    end

    if @range_preset.blank?
      s = session[:dash_range_start]
      e = session[:dash_range_end]

      if s.present? && e.present?
        begin
          @range_start = Date.parse(s)
          @range_end   = Date.parse(e)
        rescue ArgumentError
          @range_start = default_start
          @range_end   = default_end
          session[:dash_range_start] = @range_start.to_s
          session[:dash_range_end]   = @range_end.to_s
          session[:dash_is_all_time] = false
        end
      else
        @range_start = default_start
        @range_end   = default_end
        # Default to rolling last 30 days going forward
        session[:dash_range_preset] = "last_30"
        @range_preset = "last_30"
      end
    end

    # Clamp future end dates
    if @range_end > today
      @range_end = today
    end

    # ---------------------------------------------------------------------------
    # Expose "all time selected" flag for views/controllers.
    # ---------------------------------------------------------------------------
    @is_all_time = !!session[:dash_is_all_time]
  end




  private

  def last_detections_from_recent_messages(base_scope, limit: 100, message_window: nil)
    message_window ||= (ENV["LAST100_MESSAGE_WINDOW"] || "500").to_i
    message_window = 200 if message_window < 200

    # 1) Find the most recent messages (by posted_at) that have at least one qualifying detection in base_scope.
    #    Use GROUP BY to avoid DISTINCT+ORDER BY issues in Postgres.
    recent_message_ids =
      base_scope
        .group("messages.id")
        .reorder(Arel.sql("MAX(messages.posted_at) DESC"))
        .limit(message_window)
        .pluck(Arel.sql("messages.id"))

    return [] if recent_message_ids.empty?

    # 2) Pull up to N detections from those recent messages (may be fewer than N messages).
    base_scope
      .where(detections: { message_id: recent_message_ids })
      .includes(message: :channel, signal_category: { submetric: :metric })
      .reorder(Arel.sql("messages.posted_at DESC, detections.created_at DESC"))
      .limit(limit)
      .to_a
      .reverse
  end

  # ---------------------------------------------------------------------------
  # Anchor days for sparklines (inclusive of start/end)
  # ---------------------------------------------------------------------------
  def spark_anchor_days(start_day, end_day)
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

  # ---------------------------------------------------------------------------
  # Rolling 30-day POS/TOT series at anchor days.
  # daily hash: { Date => {pos:, tot:} } (missing days treated as 0/0).
  # Returns start_score/end_score and points array aligned to anchors.
  # ---------------------------------------------------------------------------
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

  def build_metric_card_data(metrics:, metric_counts: nil)
    min_detections = Clara::OverviewService::MIN_DETECTIONS
    enough_data = @days_analyzed.to_i >= 30

    metrics.each_with_object({}) do |metric, out|
      daily = fetch_daily_counts(
        start_date: @range_start - 29.days,
        end_date: @range_end,
        metric_id: metric.id
      )

      anchors = spark_anchor_days(@range_start, @range_end)
      series = rolling30_series(daily, @range_start, @range_end, anchors, reverse: metric.reverse?)
      points = series[:points].map { |v| v.round }
      points = [points.first, points.first] if points.size < 2

      curr_count = (metric_counts || {})[metric.id].to_h[:tot].to_i

      score_available = enough_data && curr_count >= min_detections
      metric_delta = (score_available && !@is_all_time) ? (points.last.to_i - points.first.to_i) : 0

      if metric.reverse?
        if metric_delta > 0
          arrow_dir = "up"
          color_dir = "down"
        else
          arrow_dir = "down"
          color_dir = "up"
        end
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
        show_trend: score_available && !@is_all_time,
        has_any_data: curr_count.positive?,
        enough_data: enough_data
      }
    end
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

  def disable_turbo_cache
    @turbo_cache_control = "no-cache"
  end

end


