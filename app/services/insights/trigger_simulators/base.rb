module Insights
  module TriggerSimulators
    class Base
      DEFAULT_MIN_WINDOW_EXPECTED_FRACTION = 0.35
      DEFAULT_MIN_WINDOW_FLOOR = 2
      DEFAULT_MIN_BASELINE_FLOOR = 6
      DEFAULT_TOP_N = 25
      DEFAULT_NEG_RATE_PRIOR_ALPHA = 2.0
      DEFAULT_NEG_RATE_PRIOR_BETA = 8.0
      DEFAULT_POS_RATE_PRIOR_ALPHA = 2.0
      DEFAULT_POS_RATE_PRIOR_BETA = 3.0
      DEFAULT_TINY_WINDOW_FLOOR = 10
      DEFAULT_TINY_BASELINE_FLOOR = 30
      CONF_VOLUME_STRONG = 25
      CONF_VOLUME_MEDIUM = 10
      CONF_SPREAD_STRONG = 3
      CONF_SPREAD_MEDIUM = 2
      CONF_EFFECT_STRONG_DELTA = 0.12
      CONF_EFFECT_MEDIUM_DELTA = 0.08
      CONF_EFFECT_STRONG_OR = 1.5
      CONF_EFFECT_MEDIUM_OR = 1.25
      CONF_EFFECT_STRONG_Z = 2.0
      CONF_EFFECT_MEDIUM_Z = 1.5
      CONF_EFFECT_STRONG_P = 0.05
      CONF_EFFECT_MEDIUM_P = 0.1
      EffectiveRollupRow = Struct.new(
        :subject_type,
        :subject_id,
        :dimension_type,
        :dimension_id,
        :metric_id,
        :window_total,
        :window_positive,
        :window_negative,
        :baseline_total,
        :baseline_positive,
        :baseline_negative,
        :effective_window_days,
        :effective_baseline_days,
        keyword_init: true
      )

      attr_reader :template, :workspace, :snapshot_at, :baseline_mode, :overrides, :logger

      def initialize(template:, workspace:, snapshot_at:, baseline_mode:, overrides:, logger: Rails.logger)
        @template = template
        @workspace = workspace
        @snapshot_at = snapshot_at
        @baseline_mode = (baseline_mode.presence || "trailing").to_s
        @overrides = (overrides || {}).to_h.with_indifferent_access
        @logger = logger
      end

      def run!
        raise NotImplementedError, "implement in subclass"
      end

      def qualifying_stats
        window_range, baseline_range = window_and_baseline_ranges
        fired, total_seen, eligible_count, rejects = evaluate_rows(window_range: window_range, baseline_range: baseline_range)

        {
          params: params_with_ranges(window_range: window_range, baseline_range: baseline_range),
          summary: {
            total_candidates: eligible_count,
            total_seen: total_seen,
            fired_candidates: fired.size,
            fire_rate: eligible_count.positive? ? (fired.size.to_f / eligible_count.to_f) : 0.0,
            reject_counts: rejects
          },
          fired: fired,
          window_range: window_range,
          baseline_range: baseline_range
        }
      end

      protected

      def params
        @params ||= {
          workspace_id: workspace.id,
          snapshot_at: snapshot_at,
          window_days: window_days,
          baseline_days: baseline_days,
          baseline_days_used: baseline_days_in_use,
          window_offset_days: window_offset_days,
          baseline_mode: baseline_mode,
          logit_margin_min: logit_margin_min,
          direction: direction,
          min_window_detections: min_window_detections,
          min_baseline_detections: min_baseline_detections,
          min_current_rate: min_current_rate,
          min_delta_rate: min_delta_rate,
          min_z_score: min_z_score,
          min_odds_ratio: min_odds_ratio,
          min_log_odds_ratio: min_log_odds_ratio,
          min_effect_z: min_effect_z,
          max_effect_p: max_effect_p,
          subject_scope: subject_scope,
          dimension_type: dimension_type,
          adaptive_windows: adaptive_windows?,
          min_window_expected_fraction: min_window_expected_fraction,
          window_floor_override: window_floor_override,
          baseline_floor_override: baseline_floor_override,
          top_n: top_n,
          trigger_template_id: template.id,
          trigger_key: template.key,
          driver_type: template.driver_type
        }
      end

      def window_days
        @window_days ||= fetch_int(:window_days, template.window_days) || 14
      end

      def baseline_days
        @baseline_days ||= fetch_int(:baseline_days, template.baseline_days) || window_days
      end

      def baseline_days_in_use
        baseline_mode == "previous_period" ? window_days : baseline_days
      end

      def window_offset_days
        @window_offset_days ||= fetch_int(:window_offset_days, template.window_offset_days) || 0
      end

      def subject_scope
        @subject_scope ||= overrides[:subject_scope].presence || template.subject_scope_list.first || template.subject_scopes.to_s.split(",").map(&:strip).reject(&:blank?).first
      end

      def dimension_type
        @dimension_type ||= overrides[:dimension_type].presence || template.dimension_type
      end

      def direction
        @direction ||= overrides[:direction].presence || template.direction.presence || "negative"
      end

      def min_window_detections
        @min_window_detections ||= fetch_int(:min_window_detections, template.min_window_detections)
      end

      def min_baseline_detections
        @min_baseline_detections ||= fetch_int(:min_baseline_detections, template.min_baseline_detections)
      end

      def min_current_rate
        @min_current_rate ||= fetch_float(:min_current_rate, template.min_current_rate)
      end

      def min_delta_rate
        @min_delta_rate ||= fetch_float(:min_delta_rate, template.min_delta_rate)
      end

      def min_z_score
        @min_z_score ||= fetch_float(:min_z_score, template.min_z_score)
      end

      def adaptive_windows?
        value = overrides[:adaptive_windows]
        value = template_metadata["adaptive_windows"] if value.nil?
        truthy?(value)
      end

      def min_odds_ratio
        @min_odds_ratio ||= fetch_float(:min_odds_ratio, template_metadata["min_odds_ratio"])
      end

      def min_log_odds_ratio
        @min_log_odds_ratio ||= fetch_float(:min_log_odds_ratio, template_metadata["min_log_odds_ratio"])
      end

      def min_effect_z
        @min_effect_z ||= fetch_float(:min_effect_z, template_metadata["min_effect_z"])
      end

      def max_effect_p
        @max_effect_p ||= fetch_float(:max_effect_p, template_metadata["max_effect_p"])
      end

      def logit_margin_min
        @logit_margin_min ||= fetch_float(:logit_margin_min, overrides[:logit_margin_min]) || ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f
      end

      def tiny_window_floor
        @tiny_window_floor ||= ENV.fetch("INSIGHTS_TINY_WINDOW_FLOOR", DEFAULT_TINY_WINDOW_FLOOR).to_i
      end

      def tiny_baseline_floor
        @tiny_baseline_floor ||= ENV.fetch("INSIGHTS_TINY_BASELINE_FLOOR", DEFAULT_TINY_BASELINE_FLOOR).to_i
      end

      def min_window_expected_fraction
        @min_window_expected_fraction ||= fetch_float(:min_window_expected_fraction, template_metadata["min_window_expected_fraction"]) || DEFAULT_MIN_WINDOW_EXPECTED_FRACTION
      end

      def window_floor_override
        @window_floor_override ||= fetch_int(:window_floor_override, template_metadata["min_window_floor"])
      end

      def baseline_floor_override
        @baseline_floor_override ||= fetch_int(:baseline_floor_override, template_metadata["min_baseline_floor"])
      end

      def top_n
        @top_n ||= fetch_int(:top_n, overrides[:top_n]) || DEFAULT_TOP_N
      end

      def template_metadata
        @template_metadata ||= (template.metadata || {}).with_indifferent_access
      end

      def window_and_baseline_ranges
        window_end = (snapshot_at - window_offset_days.days).end_of_day
        window_start = window_end - window_days.days + 1.second
        baseline_end = window_start - 1.second
        baseline_start = baseline_end - baseline_days_in_use.days + 1.second
        [window_start..window_end, baseline_start..baseline_end]
      end

      def build_time_range(start_date, end_date)
        return nil unless start_date && end_date
        start_time = start_date.beginning_of_day + 1.second
        end_time = end_date.end_of_day
        start_time..end_time
      end

      def aggregate_rows(window_range:, baseline_range:, subject_types: subject_types_for_scope(subject_scope), dimension_types: dimension_types_for(dimension_type))
        rel = InsightDetectionRollup.where(workspace_id: workspace.id, logit_margin_min: logit_margin_min)
        rel = rel.where(subject_type: subject_types) if subject_types.present?
        rel = rel.where(dimension_type: dimension_types) if dimension_types.present?
        rel = rel.where(posted_on: baseline_range.begin.to_date..window_range.end.to_date)

        window_start = window_range.begin.to_date
        window_end   = window_range.end.to_date
        base_start   = baseline_range.begin.to_date
        base_end     = baseline_range.end.to_date

        rel
          .group(:subject_type, :subject_id, :dimension_type, :dimension_id, :metric_id)
          .select(
            "subject_type",
            "subject_id",
            "dimension_type",
            "dimension_id",
            "metric_id",
            <<~SQL.squish,
              SUM(CASE WHEN posted_on BETWEEN #{quote_date(window_start)} AND #{quote_date(window_end)} THEN total_count ELSE 0 END) AS window_total
            SQL
            <<~SQL.squish,
              SUM(CASE WHEN posted_on BETWEEN #{quote_date(window_start)} AND #{quote_date(window_end)} THEN positive_count ELSE 0 END) AS window_positive
            SQL
            <<~SQL.squish,
              SUM(CASE WHEN posted_on BETWEEN #{quote_date(window_start)} AND #{quote_date(window_end)} THEN negative_count ELSE 0 END) AS window_negative
            SQL
            <<~SQL.squish,
              SUM(CASE WHEN posted_on BETWEEN #{quote_date(base_start)} AND #{quote_date(base_end)} THEN total_count ELSE 0 END) AS baseline_total
            SQL
            <<~SQL.squish,
              SUM(CASE WHEN posted_on BETWEEN #{quote_date(base_start)} AND #{quote_date(base_end)} THEN positive_count ELSE 0 END) AS baseline_positive
            SQL
            <<~SQL.squish,
              SUM(CASE WHEN posted_on BETWEEN #{quote_date(base_start)} AND #{quote_date(base_end)} THEN negative_count ELSE 0 END) AS baseline_negative
            SQL
          )
      end

      def daily_rollup_rows(window_range:, baseline_range:, subject_types: subject_types_for_scope(subject_scope), dimension_types: dimension_types_for(dimension_type))
        rel = InsightDetectionRollup.where(workspace_id: workspace.id, logit_margin_min: logit_margin_min)
        rel = rel.where(subject_type: subject_types) if subject_types.present?
        rel = rel.where(dimension_type: dimension_types) if dimension_types.present?
        rel = rel.where(posted_on: baseline_range.begin.to_date..window_range.end.to_date)

        rel.select(
          :subject_type,
          :subject_id,
          :dimension_type,
          :dimension_id,
          :metric_id,
          :posted_on,
          :total_count,
          :positive_count,
          :negative_count
        )
      end

      def evaluate_rows(window_range:, baseline_range:)
        if adaptive_windows?
          return evaluate_rows_adaptive(window_range: window_range, baseline_range: baseline_range)
        end

        rows = aggregate_rows(window_range: window_range, baseline_range: baseline_range)
        fired = []
        total_seen = 0
        eligible_count = 0
        rejects = Hash.new(0)

        rows.each do |row|
          stats = build_stats(row)
          next unless stats

          total_seen += 1
          eligible_count += 1 if stats[:eligible]
          if stats[:qualifies]
            fired << stats
          else
            Array(stats[:reject_reasons]).each { |r| rejects[r] += 1 }
          end
        end

        [fired, total_seen, eligible_count, rejects]
      end

      def evaluate_rows_adaptive(window_range:, baseline_range:)
        rows = daily_rollup_rows(window_range: window_range, baseline_range: baseline_range)
        grouped = rows.group_by { |row| [row.subject_type, row.subject_id, row.dimension_type, row.dimension_id, row.metric_id] }

        fired = []
        total_seen = 0
        eligible_count = 0
        rejects = Hash.new(0)
        window_end_date = window_range.end.to_date

        grouped.each_value do |series|
          stats = build_stats_from_series(series, window_end_date: window_end_date)
          next unless stats

          total_seen += 1
          eligible_count += 1 if stats[:eligible]
          if stats[:qualifies]
            fired << stats
          else
            Array(stats[:reject_reasons]).each { |r| rejects[r] += 1 }
          end
        end

        [fired, total_seen, eligible_count, rejects]
      end

      def build_stats_from_series(series, window_end_date:)
        first = series.first
        return nil unless first

        counts_by_date = {}
        series.each do |row|
          counts_by_date[row.posted_on] = {
            total: row.total_count.to_i,
            positive: row.positive_count.to_i,
            negative: row.negative_count.to_i
          }
        end

        effective = compute_effective_ranges(counts_by_date, window_end_date: window_end_date)

        row = EffectiveRollupRow.new(
          subject_type: first.subject_type,
          subject_id: first.subject_id,
          dimension_type: first.dimension_type,
          dimension_id: first.dimension_id,
          metric_id: first.metric_id,
          window_total: effective[:window_total],
          window_positive: effective[:window_positive],
          window_negative: effective[:window_negative],
          baseline_total: effective[:baseline_total],
          baseline_positive: effective[:baseline_positive],
          baseline_negative: effective[:baseline_negative],
          effective_window_days: effective[:window_days],
          effective_baseline_days: effective[:baseline_days]
        )

        stats = build_stats(row)
        return nil unless stats

        stats[:window_range] = effective[:window_range]
        stats[:baseline_range] = effective[:baseline_range]
        stats[:effective_window_days] = effective[:window_days]
        stats[:effective_baseline_days] = effective[:baseline_days]
        stats[:min_window_required] = effective[:min_window_required]
        stats[:min_baseline_required] = effective[:min_baseline_required]
        stats[:window_days_with_volume] = effective[:window_days_with_volume]

        stats
      end

      def compute_effective_ranges(counts_by_date, window_end_date:)
        zero = { total: 0, positive: 0, negative: 0 }
        min_window_required = window_floor_override || min_window_detections || DEFAULT_MIN_WINDOW_FLOOR
        min_baseline_required = baseline_floor_override || min_baseline_detections || DEFAULT_MIN_BASELINE_FLOOR

        window_total = 0
        window_positive = 0
        window_negative = 0
        window_days_used = 0
        window_start_date = window_end_date

        day = window_end_date
        while window_days_used < window_days
          counts = counts_by_date[day] || zero
          window_total += counts[:total]
          window_positive += counts[:positive]
          window_negative += counts[:negative]
          window_days_used += 1
          window_start_date = day
          break if window_total >= min_window_required.to_i
          day -= 1.day
        end

        baseline_days_cap = baseline_mode == "previous_period" ? window_days_used : baseline_days_in_use
        baseline_end_date = window_start_date - 1.day
        baseline_total = 0
        baseline_positive = 0
        baseline_negative = 0
        baseline_days_used = 0
        baseline_start_date = baseline_end_date

        day = baseline_end_date
        while baseline_days_used < baseline_days_cap
          counts = counts_by_date[day] || zero
          baseline_total += counts[:total]
          baseline_positive += counts[:positive]
          baseline_negative += counts[:negative]
          baseline_days_used += 1
          baseline_start_date = day
          break if baseline_total >= min_baseline_required.to_i
          day -= 1.day
        end

        window_range = build_time_range(window_start_date, window_end_date)
        baseline_range = build_time_range(baseline_start_date, baseline_end_date)
        window_days_with_volume = counts_by_date.count do |date, counts|
          date >= window_start_date && date <= window_end_date && counts[:total].to_i.positive?
        end

        {
          window_total: window_total,
          window_positive: window_positive,
          window_negative: window_negative,
          baseline_total: baseline_total,
          baseline_positive: baseline_positive,
          baseline_negative: baseline_negative,
          window_range: window_range,
          baseline_range: baseline_range,
          window_days: window_days_used,
          baseline_days: baseline_days_used,
          window_days_with_volume: window_days_with_volume,
          min_window_required: min_window_required.to_i,
          min_baseline_required: min_baseline_required.to_i
        }
      end

      def result(params:, fired:, total_seen:, eligible_count:, rejects: {})
        top_candidates = fired.sort_by { |r| -r[:score].to_f }.first(top_n)

        TriggerSimulation::Result.new(
          params: params,
          summary: {
            total_candidates: eligible_count,
            total_seen: total_seen,
            fired_candidates: fired.size,
            fire_rate: eligible_count.positive? ? (fired.size.to_f / eligible_count.to_f) : 0.0,
            reject_counts: rejects
          },
          top_candidates: top_candidates
        )
      end

      def subject_types_for_scope(scope)
        case scope.to_s
        when "user" then ["IntegrationUser"]
        when "group" then ["Group"]
        when "admin", "workspace" then ["Workspace"]
        when "", nil then nil
        else [scope.to_s.classify]
        end
      end

      def dimension_types_for(dim)
        return nil unless dim.present?
        Array(dim)
      end

      def dynamic_min_window(baseline_total:)
        floor = window_floor_override || min_window_detections || DEFAULT_MIN_WINDOW_FLOOR
        expected = baseline_total.to_f * window_days.to_f / [baseline_days_in_use.to_f, 1.0].max
        adaptive = (expected * min_window_expected_fraction.to_f).ceil
        [floor, adaptive].max
      end

      def dynamic_min_window_for(row, baseline_total:)
        floor = window_floor_override || min_window_detections || DEFAULT_MIN_WINDOW_FLOOR
        window_days_used = effective_window_days_for(row)
        baseline_days_used = effective_baseline_days_for(row)
        expected = baseline_total.to_f * window_days_used.to_f / [baseline_days_used.to_f, 1.0].max
        adaptive = (expected * min_window_expected_fraction.to_f).ceil
        [floor, adaptive].max
      end

      def dynamic_min_baseline
        raw_floors = [baseline_floor_override, min_baseline_detections].compact
        raw_floors = [DEFAULT_MIN_BASELINE_FLOOR] if raw_floors.empty?

        floors = raw_floors.map { |c| scale_baseline_count(c) }.compact
        floors.max || DEFAULT_MIN_BASELINE_FLOOR
      end

      def dynamic_min_baseline_for(row)
        raw_floors = [baseline_floor_override, min_baseline_detections].compact
        raw_floors = [DEFAULT_MIN_BASELINE_FLOOR] if raw_floors.empty?

        baseline_days_used = effective_baseline_days_for(row)
        floors = raw_floors.map { |c| scale_baseline_count(c, baseline_days_override: baseline_days_used) }.compact
        floors.max || DEFAULT_MIN_BASELINE_FLOOR
      end

      def scale_baseline_count(count, baseline_days_override: nil)
        return nil unless count
        from_days = template.baseline_days || baseline_days
        to_days = baseline_days_override || baseline_days_in_use
        return count.to_i if from_days.to_f <= 0 || to_days.to_f <= 0

        ((count.to_f * to_days.to_f) / from_days.to_f).ceil
      end

      def effective_window_days_for(row)
        return row.effective_window_days.to_i if row.respond_to?(:effective_window_days) && row.effective_window_days.present?
        window_days
      end

      def effective_baseline_days_for(row)
        return row.effective_baseline_days.to_i if row.respond_to?(:effective_baseline_days) && row.effective_baseline_days.present?
        baseline_days_in_use
      end

      def smoothed_rate(count, total, negative: false)
        alpha, beta = negative ? [DEFAULT_NEG_RATE_PRIOR_ALPHA, DEFAULT_NEG_RATE_PRIOR_BETA] : [DEFAULT_POS_RATE_PRIOR_ALPHA, DEFAULT_POS_RATE_PRIOR_BETA]
        denom = total.to_f + alpha + beta
        return 0.0 if denom <= 0

        (count.to_f + alpha) / denom
      end

      def compute_z_score(window_rate:, window_total:, compare_rate:, compare_total:)
        return 0.0 if window_total.to_i <= 0 || compare_total.to_i <= 0

        pooled_rate = ((window_rate * window_total) + (compare_rate * compare_total)) / (window_total + compare_total)
        variance = pooled_rate * (1 - pooled_rate) * ((1.0 / window_total) + (1.0 / compare_total))
        return 0.0 if variance <= 0

        (window_rate - compare_rate) / Math.sqrt(variance)
      end

      def compute_effect_stats(window_total:, window_positive:, window_negative:, baseline_total:, baseline_positive:, baseline_negative:,
                               window_pos_rate:, window_neg_rate:, baseline_pos_rate:, baseline_neg_rate:)
        return {} if window_total.to_i <= 0 || baseline_total.to_i <= 0

        use_direction = direction.to_s
        if use_direction.blank? || use_direction == "neutral"
          neg_delta = window_neg_rate - baseline_neg_rate
          pos_delta = window_pos_rate - baseline_pos_rate
          use_direction = neg_delta.abs >= pos_delta.abs ? "negative" : "positive"
        end

        window_success_raw =
          if use_direction == "positive"
            window_positive
          else
            window_negative
          end

        baseline_success_raw =
          if use_direction == "positive"
            baseline_positive
          else
            baseline_negative
          end

        # Haldane-Anscombe smoothing to avoid zero division.
        window_success = window_success_raw.to_f + 0.5
        window_failure = (window_total - window_success_raw).to_f + 0.5
        baseline_success = baseline_success_raw.to_f + 0.5
        baseline_failure = (baseline_total - baseline_success_raw).to_f + 0.5

        odds_ratio = (window_success / window_failure) / (baseline_success / baseline_failure)
        log_odds_ratio = Math.log(odds_ratio)
        log_odds_se = Math.sqrt((1.0 / window_success) + (1.0 / window_failure) + (1.0 / baseline_success) + (1.0 / baseline_failure))
        effect_z = log_odds_se.positive? ? (log_odds_ratio / log_odds_se) : 0.0
        effect_p = log_odds_se.positive? ? (2.0 * (1.0 - normal_cdf(effect_z.abs))) : 1.0

        {
          odds_ratio: odds_ratio,
          log_odds_ratio: log_odds_ratio,
          log_odds_se: log_odds_se,
          effect_z: effect_z,
          effect_p: effect_p,
          effect_direction: use_direction
        }
      end

      def apply_effect_gates(qualifies, reject_reasons, stats)
        return qualifies unless qualifies

        if min_odds_ratio && stats[:odds_ratio] && stats[:odds_ratio] < min_odds_ratio.to_f
          reject_reasons << :min_odds_ratio
          qualifies = false
        end

        if qualifies && min_log_odds_ratio && stats[:log_odds_ratio] && stats[:log_odds_ratio] < min_log_odds_ratio.to_f
          reject_reasons << :min_log_odds_ratio
          qualifies = false
        end

        if qualifies && min_effect_z && stats[:effect_z] && stats[:effect_z] < min_effect_z.to_f
          reject_reasons << :min_effect_z
          qualifies = false
        end

        if qualifies && max_effect_p && stats[:effect_p] && stats[:effect_p] > max_effect_p.to_f
          reject_reasons << :max_effect_p
          qualifies = false
        end

        qualifies
      end

      def effect_gate_reasons(stats)
        stats = stats.with_indifferent_access
        reasons = []

        if min_odds_ratio && stats[:odds_ratio] && stats[:odds_ratio] < min_odds_ratio.to_f
          reasons << :min_odds_ratio
        end

        if min_log_odds_ratio && stats[:log_odds_ratio] && stats[:log_odds_ratio] < min_log_odds_ratio.to_f
          reasons << :min_log_odds_ratio
        end

        if min_effect_z && stats[:effect_z] && stats[:effect_z] < min_effect_z.to_f
          reasons << :min_effect_z
        end

        if max_effect_p && stats[:effect_p] && stats[:effect_p] > max_effect_p.to_f
          reasons << :max_effect_p
        end

        if min_z_score && stats[:z_score] && stats[:z_score] < min_z_score.to_f
          reasons << :min_z_score
        end

        reasons
      end

      def normal_cdf(value)
        0.5 * (1.0 + Math.erf(value / Math.sqrt(2.0)))
      end

      def tiny_sample?(window_total, baseline_total)
        window_total.to_i < tiny_window_floor || baseline_total.to_i < tiny_baseline_floor
      end

      def confidence_stats(stats)
        stats = stats.with_indifferent_access
        window_total = stats[:window_total].to_i
        spread_days = stats[:window_days_with_volume].presence ||
          stats[:effective_window_days].presence ||
          window_days

        volume_strength =
          if window_total >= CONF_VOLUME_STRONG
            2
          elsif window_total >= CONF_VOLUME_MEDIUM
            1
          else
            0
          end

        spread_strength =
          if spread_days.to_i >= CONF_SPREAD_STRONG
            2
          elsif spread_days.to_i >= CONF_SPREAD_MEDIUM
            1
          else
            0
          end

        delta = stats[:delta_rate]
        odds_ratio = stats[:odds_ratio]
        effect_z = stats[:effect_z]
        effect_p = stats[:effect_p]

        effect_strength = confidence_effect_strength(delta: delta, odds_ratio: odds_ratio, effect_z: effect_z, effect_p: effect_p)

        label =
          if volume_strength == 2 && spread_strength == 2 && effect_strength >= 1
            "high"
          elsif volume_strength >= 1 && spread_strength >= 1 && effect_strength >= 1
            "medium"
          else
            "low"
          end

        {
          confidence_label: label,
          confidence_score: volume_strength + spread_strength + effect_strength,
          confidence_volume_strength: volume_strength,
          confidence_spread_strength: spread_strength,
          confidence_effect_strength: effect_strength
        }
      end

      def confidence_effect_strength(delta:, odds_ratio:, effect_z:, effect_p:)
        delta_val = delta.to_f
        or_val = odds_ratio.to_f
        z_val = effect_z.to_f
        p_val = effect_p.to_f

        return 2 if (effect_z && z_val >= CONF_EFFECT_STRONG_Z) ||
          (effect_p && p_val <= CONF_EFFECT_STRONG_P) ||
          (odds_ratio && or_val >= CONF_EFFECT_STRONG_OR) ||
          (delta && delta_val >= CONF_EFFECT_STRONG_DELTA)

        return 1 if (effect_z && z_val >= CONF_EFFECT_MEDIUM_Z) ||
          (effect_p && p_val <= CONF_EFFECT_MEDIUM_P) ||
          (odds_ratio && or_val >= CONF_EFFECT_MEDIUM_OR) ||
          (delta && delta_val >= CONF_EFFECT_MEDIUM_DELTA)

        0
      end

      def score_for(stats:)
        Insights::Severity.score(template: template, stats: stats)
      end

      def params_with_ranges(window_range:, baseline_range:)
        params.merge(
          window_start_at: window_range.begin,
          window_end_at: window_range.end,
          baseline_start_at: baseline_range.begin,
          baseline_end_at: baseline_range.end
        )
      end

      def quote_date(date)
        ActiveRecord::Base.connection.quote(date)
      end

      def truthy?(value)
        return false if value.nil?
        return value if value == true || value == false
        %w[1 true yes y].include?(value.to_s.strip.downcase)
      end

      def fetch_int(key, fallback = nil)
        raw = overrides[key]
        raw = fallback if raw.nil?
        return nil unless raw.present?
        raw.to_i
      end

      def fetch_float(key, fallback = nil)
        raw = overrides[key]
        raw = fallback if raw.nil?
        return nil unless raw.present?
        raw.to_f
      end
    end
  end
end

