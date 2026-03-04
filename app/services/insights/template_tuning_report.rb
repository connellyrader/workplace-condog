# app/services/insights/template_tuning_report.rb
require "csv"

module Insights
  class TemplateTuningReport
    POSTED_AT_SQL = "COALESCE(messages.posted_at, messages.created_at)".freeze
    DEFAULT_MIN_WINDOW_EXPECTED_FRACTION = 0.35
    DEFAULT_MIN_WINDOW_FLOOR = 2
    DEFAULT_MIN_BASELINE_FLOOR = 6
    DEFAULT_RATE_PRIOR_ALPHA = 1.0
    DEFAULT_RATE_PRIOR_BETA = 1.0
    DEFAULT_NEG_RATE_PRIOR_ALPHA = 2.0
    DEFAULT_NEG_RATE_PRIOR_BETA = 8.0
    DEFAULT_POS_RATE_PRIOR_ALPHA = 2.0
    DEFAULT_POS_RATE_PRIOR_BETA = 3.0

    DEFAULT_HEADERS = [
      "as_of",
      "workspace_id",
      "template_key",
      "driver_type",
      "scope",
      "dimension_type",
      "subject_id",
      "dimension_id",
      "window_total",
      "window_negative_count",
      "window_positive_count",
      "window_negative_rate",
      "window_positive_rate",
      "baseline_total",
      "baseline_negative_count",
      "baseline_positive_count",
      "baseline_negative_rate",
      "baseline_positive_rate",
      "delta_negative_rate",
      "delta_positive_rate",
      "relative_change",
      "org_rate",
      "group_delta_vs_org",
      "z_score"
    ].freeze

    GRID_HEADERS = [
      "template_key",
      "driver_type",
      "scope",
      "dimension_type",
      "target_rate",
      "min_window_detections",
      "min_baseline_detections",
      "min_current_rate",
      "min_delta_rate",
      "min_z_score",
      "fired",
      "total",
      "fire_rate"
    ].freeze

    SimRow = Struct.new(
      :window_total,
      :baseline_total,
      :window_negative_rate,
      :window_positive_rate,
      :delta_negative_rate,
      :delta_positive_rate,
      :relative_change,
      :org_rate,
      :group_delta_vs_org,
      :z_score,
      keyword_init: true
    )

    def initialize(
      workspaces:,
      as_ofs:,
      lookback_days: 90,
      sample_users: 50,
      sample_groups: 50,
      max_dims_per_subject: 50,
      pending_only: false,
      template_keys: nil,
      output_path: "tmp/insights_baseline_stats.csv",
      logger: Rails.logger,
      logit_margin_threshold: ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f,

      simulate_grid: true,
      grid_output_path: "tmp/insights_threshold_grid.csv",
      grid_top_n: 10,
      grid_max_fire_rate: 0.10,
      target_fire_rate_user: 0.02,
      target_fire_rate_group: 0.03,
      grid_max_rows: 5000
    )
      @workspaces = Array(workspaces)
      @as_ofs = Array(as_ofs)
      @lookback_days = lookback_days
      @sample_users = sample_users
      @sample_groups = sample_groups
      @max_dims_per_subject = max_dims_per_subject
      @pending_only = pending_only
      @template_keys = template_keys
      @output_path = output_path
      @logger = logger
      @logit_margin_threshold = logit_margin_threshold

      @simulate_grid = simulate_grid
      @grid_output_path = grid_output_path
      @grid_top_n = grid_top_n
      @grid_max_fire_rate = grid_max_fire_rate
      @target_fire_rate_user = target_fire_rate_user
      @target_fire_rate_group = target_fire_rate_group
      @grid_max_rows = grid_max_rows
    end

    def run!
      templates = InsightTriggerTemplate.enabled.to_a
      templates.reject! { |t| t.driver_type == "exec_summary" }
      templates.select! { |t| @template_keys.include?(t.key) } if @template_keys.present?

      summaries = []
      sim_rows_by_template = Hash.new { |h, k| h[k] = [] } # key: [template.key, template.subject_scopes]

      CSV.open(@output_path, "w", write_headers: true, headers: DEFAULT_HEADERS) do |csv|
        @workspaces.each do |workspace|
          @as_ofs.each do |as_of|
            templates.each do |template|
              rows = rows_for_template(workspace: workspace, template: template, as_of: as_of)
              rows.each { |r| csv << DEFAULT_HEADERS.map { |h| r[h] } }
              summaries << summarize_template_rows(template: template, rows: rows) if rows.any?

              if @simulate_grid && rows.any?
                key = [template.key, template.subject_scopes.to_s]
                append_sim_rows!(sim_rows_by_template[key], rows, limit: @grid_max_rows)
              end
            end
          end
        end
      end

      summary = summaries
        .group_by { |s| [s[:template_key], s[:scope]] }
        .map { |_k, group| merge_summaries(group) }
        .sort_by { |s| [s[:template_key], s[:scope]] }

      grid_recommendations = []
      if @simulate_grid
        grid_recommendations = run_grid_simulation!(templates: templates, sim_rows_by_template: sim_rows_by_template)
      end

      { summary: summary, grid_recommendations: grid_recommendations }
    end

    private

    attr_reader :logger

    # ---------------------------
    # Dispatcher
    # ---------------------------

    def rows_for_template(workspace:, template:, as_of:)
      scope = template.subject_scopes.to_s.strip
      return [] unless %w[user group admin].include?(scope)

      case template.driver_type
      when "group_outlier_vs_org", "group_bright_spot_vs_org"
        rows_for_group_vs_org(workspace: workspace, template: template, as_of: as_of)
      when "category_volume_spike", "category_negative_rate_spike"
        rows_for_category(workspace: workspace, template: template, as_of: as_of)
      when "submetric_concentration_of_negatives", "submetric_negative_rate_spike"
        rows_for_submetric(workspace: workspace, template: template, as_of: as_of)
      else
        rows_for_metric(workspace: workspace, template: template, as_of: as_of)
      end
    end

    # ---------------------------
    # Subject sampling
    # ---------------------------

    def top_subject_ids(workspace:, scope:, as_of:)
      since = as_of - @lookback_days.days
      rel = base_workspace_scope(workspace, as_of)
              .where("#{POSTED_AT_SQL} >= ?", since)

      case scope
      when "user"
        rel = rel.joins(message: { integration_user: :user })
                 .group("integration_users.user_id")
                 .order(Arel.sql("COUNT(*) DESC"))
                 .limit(@sample_users)
        rel.pluck("integration_users.user_id")
      when "group"
        rel = rel.joins(message: { integration_user: { group_members: :group } })
                 .group("group_members.group_id")
                 .order(Arel.sql("COUNT(*) DESC"))
                 .limit(@sample_groups)
        rel.pluck("group_members.group_id")
      else
        []
      end
    end

    def dimension_ids_for_subject(workspace:, scope:, subject_id:, dimension_type:, as_of:)
      rel = detections_scope(workspace, scope, subject_id, as_of)

      col =
        case dimension_type
        when "metric"    then :metric_id
        when "submetric" then :submetric_id
        when "category"  then :signal_category_id
        else
          return []
        end

      rel.where.not(col => nil).distinct.pluck(col).first(@max_dims_per_subject)
    end

    # ---------------------------
    # Row builders
    # ---------------------------

    def rows_for_metric(workspace:, template:, as_of:)
      scope = template.subject_scopes.to_s
      subject_ids = top_subject_ids(workspace: workspace, scope: scope, as_of: as_of)
      return [] if subject_ids.empty?

      rows = []

      subject_ids.each do |subject_id|
        metric_ids = dimension_ids_for_subject(workspace: workspace, scope: scope, subject_id: subject_id, dimension_type: "metric", as_of: as_of)
        metric_ids.each do |metric_id|
          stats = rate_stats_for(
            workspace: workspace, scope: scope, subject_id: subject_id,
            filter: { metric_id: metric_id }, template: template, as_of: as_of
          )

          rows << stats_to_row(
            as_of: as_of, workspace: workspace, template: template, scope: scope,
            dimension_type: "metric", subject_id: subject_id, dimension_id: metric_id, stats: stats
          )
        end
      end

      rows
    end

    def rows_for_submetric(workspace:, template:, as_of:)
      scope = template.subject_scopes.to_s
      subject_ids = top_subject_ids(workspace: workspace, scope: scope, as_of: as_of)
      return [] if subject_ids.empty?

      rows = []

      subject_ids.each do |subject_id|
        submetric_ids = dimension_ids_for_subject(workspace: workspace, scope: scope, subject_id: subject_id, dimension_type: "submetric", as_of: as_of)
        submetric_ids.each do |submetric_id|
          stats = rate_stats_for(
            workspace: workspace, scope: scope, subject_id: subject_id,
            filter: { submetric_id: submetric_id }, template: template, as_of: as_of
          )

          rows << stats_to_row(
            as_of: as_of, workspace: workspace, template: template, scope: scope,
            dimension_type: "submetric", subject_id: subject_id, dimension_id: submetric_id, stats: stats
          )
        end
      end

      rows
    end

    def rows_for_category(workspace:, template:, as_of:)
      scope = template.subject_scopes.to_s
      subject_ids = top_subject_ids(workspace: workspace, scope: scope, as_of: as_of)
      return [] if subject_ids.empty?

      rows = []

      subject_ids.each do |subject_id|
        category_ids = dimension_ids_for_subject(workspace: workspace, scope: scope, subject_id: subject_id, dimension_type: "category", as_of: as_of)
        category_ids.each do |category_id|
          stats = rate_stats_for(
            workspace: workspace, scope: scope, subject_id: subject_id,
            filter: { signal_category_id: category_id }, template: template, as_of: as_of
          )

          # volume relative change (used by category_volume_spike)
          stats[:relative_change] =
            (stats[:window_total].to_i - stats[:baseline_total].to_i).to_f / [stats[:baseline_total].to_i, 1].max

          rows << stats_to_row(
            as_of: as_of, workspace: workspace, template: template, scope: scope,
            dimension_type: "category", subject_id: subject_id, dimension_id: category_id, stats: stats
          )
        end
      end

      rows
    end

    def rows_for_group_vs_org(workspace:, template:, as_of:)
      # compares each group to org-wide in the same window
      group_ids = top_subject_ids(workspace: workspace, scope: "group", as_of: as_of)
      return [] if group_ids.empty?

      metric_ids = base_workspace_scope(workspace, as_of).where.not(metric_id: nil).distinct.pluck(:metric_id)
      metric_ids = metric_ids.first(@max_dims_per_subject)

      rows = []

      metric_ids.each do |metric_id|
        org_stats = rate_stats_for(
          workspace: workspace, scope: "admin", subject_id: nil,
          filter: { metric_id: metric_id }, template: template, as_of: as_of
        )

        org_rate =
          template.direction == "negative" ? org_stats[:window_negative_rate].to_f : org_stats[:window_positive_rate].to_f

        group_ids.each do |group_id|
          g_stats = rate_stats_for(
            workspace: workspace, scope: "group", subject_id: group_id,
            filter: { metric_id: metric_id }, template: template, as_of: as_of
          )

          group_rate =
            template.direction == "negative" ? g_stats[:window_negative_rate].to_f : g_stats[:window_positive_rate].to_f

          delta = group_rate - org_rate
          z = compute_z_score(
            window_rate: group_rate,
            window_total: g_stats[:window_total].to_i,
            compare_rate: org_rate,
            compare_total: org_stats[:window_total].to_i
          )

          g_stats[:org_rate] = org_rate
          g_stats[:group_delta_vs_org] = delta
          g_stats[:z_score] = z

          rows << stats_to_row(
            as_of: as_of, workspace: workspace, template: template, scope: "group",
            dimension_type: "metric", subject_id: group_id, dimension_id: metric_id, stats: g_stats
          )
        end
      end

      rows
    end

    # ---------------------------
    # Stats helpers
    # ---------------------------

    def rate_stats_for(workspace:, scope:, subject_id:, filter:, template:, as_of:)
      window_range, baseline_range = window_and_baseline_ranges(template, as_of)

      base = detections_scope(workspace, scope, subject_id, as_of)
      base = base.where(filter) if filter.present?

      window_scope = in_range(base, window_range)
      baseline_scope = in_range(base, baseline_range)

      window_total = window_scope.count
      window_negative = window_scope.where(polarity: "negative").count
      window_positive = window_scope.where(polarity: "positive").count

      baseline_total = baseline_scope.count
      baseline_negative = baseline_scope.where(polarity: "negative").count
      baseline_positive = baseline_scope.where(polarity: "positive").count

      alpha, beta = rate_priors(template)

      window_negative_rate   = smoothed_rate(window_negative, window_total, alpha: alpha, beta: beta)
      window_positive_rate   = smoothed_rate(window_positive, window_total, alpha: alpha, beta: beta)
      baseline_negative_rate = smoothed_rate(baseline_negative, baseline_total, alpha: alpha, beta: beta)
      baseline_positive_rate = smoothed_rate(baseline_positive, baseline_total, alpha: alpha, beta: beta)
      z_score =
        if template.min_z_score.present?
          compare_rate =
            case template.direction
            when "negative" then baseline_negative_rate
            when "positive" then baseline_positive_rate
            else baseline_negative_rate
            end

          window_rate =
            case template.direction
            when "negative" then window_negative_rate
            when "positive" then window_positive_rate
            else window_negative_rate
            end

          compute_z_score(
            window_rate: window_rate,
            window_total: window_total,
            compare_rate: compare_rate,
            compare_total: baseline_total
          )
        end

      {
        window_total: window_total,
        window_negative_count: window_negative,
        window_positive_count: window_positive,
        window_negative_rate: window_negative_rate,
        window_positive_rate: window_positive_rate,
        baseline_total: baseline_total,
        baseline_negative_count: baseline_negative,
        baseline_positive_count: baseline_positive,
        baseline_negative_rate: baseline_negative_rate,
        baseline_positive_rate: baseline_positive_rate,
        delta_negative_rate: window_negative_rate - baseline_negative_rate,
        delta_positive_rate: window_positive_rate - baseline_positive_rate,
        z_score: z_score
      }
    end

    def window_and_baseline_ranges(template, as_of)
      window_days   = template.window_days.to_i
      baseline_days = template.baseline_days.to_i
      offset_days   = template.window_offset_days.to_i

      window_end   = (as_of - offset_days.days).end_of_day
      window_start = window_end - window_days.days + 1.second

      baseline_end   = window_start - 1.second
      baseline_start = baseline_end - baseline_days.days + 1.second

      [window_start..window_end, baseline_start..baseline_end]
    end

    def base_workspace_scope(workspace, as_of)
      scope = Detection
        .for_workspace(workspace.id)
        .with_scoring_policy
        .joins(:message)
        .where("#{POSTED_AT_SQL} <= ?", as_of)

      scope = scope.insight_pending if @pending_only && scope.respond_to?(:insight_pending)
      scope
    end

    def detections_scope(workspace, scope, subject_id, as_of)
      rel = base_workspace_scope(workspace, as_of)

      case scope
      when "user"
        rel.joins(message: { integration_user: :user })
           .where(integration_users: { user_id: subject_id })
      when "group"
        rel.joins(message: { integration_user: { group_members: :group } })
           .where(group_members: { group_id: subject_id })
      when "admin"
        rel
      else
        rel.none
      end
    end

    def in_range(scope, range)
      scope.where("#{POSTED_AT_SQL} BETWEEN :start_at AND :end_at",
                  start_at: range.begin, end_at: range.end)
    end

    def rate_priors(template)
      meta = template.metadata || {}
      alpha = meta["rate_prior_alpha"]
      beta  = meta["rate_prior_beta"]

      if alpha && beta
        [alpha.to_f, beta.to_f]
      else
        case template.direction
        when "negative"
          [DEFAULT_NEG_RATE_PRIOR_ALPHA, DEFAULT_NEG_RATE_PRIOR_BETA]
        when "positive"
          [DEFAULT_POS_RATE_PRIOR_ALPHA, DEFAULT_POS_RATE_PRIOR_BETA]
        else
          [DEFAULT_RATE_PRIOR_ALPHA, DEFAULT_RATE_PRIOR_BETA]
        end
      end
    end

    def smoothed_rate(count, total, alpha:, beta:)
      denom = total.to_f + alpha.to_f + beta.to_f
      return 0.0 if denom <= 0

      (count.to_f + alpha.to_f) / denom
    end

    def dynamic_min_window(template, stats, floor_override: nil)
      meta = template.metadata || {}
      frac = (meta["min_window_expected_fraction"] || DEFAULT_MIN_WINDOW_EXPECTED_FRACTION).to_f
      floor = (floor_override || meta["min_window_floor"] || template.min_window_detections || DEFAULT_MIN_WINDOW_FLOOR).to_i
      baseline_total =
        if stats.respond_to?(:[])
          stats[:baseline_total] || stats["baseline_total"]
        elsif stats.respond_to?(:baseline_total)
          stats.baseline_total
        end
      expected = baseline_total.to_f * template.window_days.to_f / [template.baseline_days.to_i, 1].max

      [floor, (expected * frac).ceil].max
    end

    def dynamic_min_baseline(template, floor_override: nil)
      meta = template.metadata || {}
      floor = (floor_override || template.min_baseline_detections).to_i

      [floor, (meta["min_baseline_floor"] || DEFAULT_MIN_BASELINE_FLOOR).to_i].max
    end

    def compute_z_score(window_rate:, window_total:, compare_rate:, compare_total:)
      return 0.0 if window_total.to_i <= 0 || compare_total.to_i <= 0

      pooled_rate = ((window_rate * window_total) + (compare_rate * compare_total)) / (window_total + compare_total)
      variance = pooled_rate * (1 - pooled_rate) * ((1.0 / window_total) + (1.0 / compare_total))
      return 0.0 if variance <= 0

      (window_rate - compare_rate) / Math.sqrt(variance)
    end

    # ---------------------------
    # Output formatting
    # ---------------------------

    def stats_to_row(as_of:, workspace:, template:, scope:, dimension_type:, subject_id:, dimension_id:, stats:)
      {
        "as_of" => as_of.iso8601,
        "workspace_id" => workspace.id,
        "template_key" => template.key,
        "driver_type" => template.driver_type,
        "scope" => scope,
        "dimension_type" => dimension_type,
        "subject_id" => subject_id,
        "dimension_id" => dimension_id,

        "window_total" => stats[:window_total],
        "window_negative_count" => stats[:window_negative_count],
        "window_positive_count" => stats[:window_positive_count],
        "window_negative_rate" => stats[:window_negative_rate],
        "window_positive_rate" => stats[:window_positive_rate],

        "baseline_total" => stats[:baseline_total],
        "baseline_negative_count" => stats[:baseline_negative_count],
        "baseline_positive_count" => stats[:baseline_positive_count],
        "baseline_negative_rate" => stats[:baseline_negative_rate],
        "baseline_positive_rate" => stats[:baseline_positive_rate],

        "delta_negative_rate" => stats[:delta_negative_rate],
        "delta_positive_rate" => stats[:delta_positive_rate],

        "relative_change" => stats[:relative_change],
        "org_rate" => stats[:org_rate],
        "group_delta_vs_org" => stats[:group_delta_vs_org],
        "z_score" => stats[:z_score]
      }
    end

    # ---------------------------
    # Grid simulation
    # ---------------------------

    def run_grid_simulation!(templates:, sim_rows_by_template:)
      recommendations = []

      CSV.open(@grid_output_path, "w", write_headers: true, headers: GRID_HEADERS) do |csv|
        templates.each do |template|
          scope = template.subject_scopes.to_s
          key = [template.key, scope]
          rows = sim_rows_by_template[key]
          next if rows.blank?

          target_rate = target_rate_for_scope(scope)
          grid = threshold_grid_for(template, rows)

          best = nil
          best_distance = nil

          grid.each do |th|
            fired, total = simulate_fires(template, rows, th)
            fire_rate = total.positive? ? (fired.to_f / total.to_f) : 0.0

            csv << [
              template.key,
              template.driver_type,
              scope,
              template.dimension_type,
              target_rate,
              th[:min_window_detections],
              th[:min_baseline_detections],
              th[:min_current_rate],
              th[:min_delta_rate],
              th[:min_z_score],
              fired,
              total,
              fire_rate
            ]

            next if fire_rate > @grid_max_fire_rate

            dist = (fire_rate - target_rate).abs
            if best.nil? || dist < best_distance
              best = { thresholds: th, fired: fired, total: total, fire_rate: fire_rate }
              best_distance = dist
            end
          end

          recommendations << { template_key: template.key, scope: scope, target_rate: target_rate, best: best } if best
        end
      end

      recommendations.sort_by { |r| [r[:template_key], r[:scope]] }
    end

    def simulate_fires(template, rows, th)
      fired = 0
      total = rows.length

      rows.each do |r|
        min_window = dynamic_min_window(template, r, floor_override: th[:min_window_detections])
        min_baseline = dynamic_min_baseline(template, floor_override: th[:min_baseline_detections])

        next if r.window_total.to_i < min_window
        next if r.baseline_total.to_i < min_baseline

        if template.driver_type == "category_volume_spike"
          next if r.relative_change.to_f < th[:min_delta_rate].to_f
          fired += 1
          next
        end

        if %w[group_outlier_vs_org group_bright_spot_vs_org].include?(template.driver_type)
          current_rate = template.direction == "negative" ? r.window_negative_rate.to_f : r.window_positive_rate.to_f
          delta = r.group_delta_vs_org.to_f
          z = r.z_score.to_f

          next if current_rate < th[:min_current_rate].to_f
          next if delta < th[:min_delta_rate].to_f
          next if th[:min_z_score] && z < th[:min_z_score].to_f

          fired += 1
          next
        end

        current_rate =
          case template.direction
          when "negative" then r.window_negative_rate.to_f
          when "positive" then r.window_positive_rate.to_f
          else [r.window_negative_rate.to_f, r.window_positive_rate.to_f].max
          end

        delta_rate =
          case template.direction
          when "negative" then r.delta_negative_rate.to_f
          when "positive" then r.delta_positive_rate.to_f
          else [r.delta_negative_rate.to_f.abs, r.delta_positive_rate.to_f.abs].max
          end

        next if current_rate < th[:min_current_rate].to_f
        next if delta_rate < th[:min_delta_rate].to_f
        if th[:min_z_score]
          z = r.z_score.to_f
          next if z.nan? || z < th[:min_z_score].to_f
        end

        fired += 1
      end

      [fired, total]
    end

    def threshold_grid_for(template, rows)
      window_totals = rows.map { |r| r.window_total.to_i }
      baseline_totals = rows.map { |r| r.baseline_total.to_i }

      rates =
        if %w[group_outlier_vs_org group_bright_spot_vs_org].include?(template.driver_type)
          rows.map { |r| template.direction == "negative" ? r.window_negative_rate.to_f : r.window_positive_rate.to_f }
        else
          rows.map do |r|
            case template.direction
            when "negative" then r.window_negative_rate.to_f
            when "positive" then r.window_positive_rate.to_f
            else [r.window_negative_rate.to_f, r.window_positive_rate.to_f].max
            end
          end
        end

      deltas =
        if template.driver_type == "category_volume_spike"
          rows.map { |r| r.relative_change.to_f }.select { |v| v > 0 }
        elsif %w[group_outlier_vs_org group_bright_spot_vs_org].include?(template.driver_type)
          rows.map { |r| r.group_delta_vs_org.to_f }.select { |v| v > 0 }
        else
          vals =
            case template.direction
            when "negative" then rows.map { |r| r.delta_negative_rate.to_f }
            when "positive" then rows.map { |r| r.delta_positive_rate.to_f }
            else rows.map { |r| [r.delta_negative_rate.to_f.abs, r.delta_positive_rate.to_f.abs].max }
            end
          vals.select { |v| v > 0 }
        end

      zscores = rows.map { |r| r.z_score }.compact.map(&:to_f)

      win_grid  = int_grid(window_totals, fallback: [1, 3, 5, 8, 12]).take(4)
      base_grid = int_grid(baseline_totals, fallback: [1, 5, 10, 15, 25]).take(4)
      rate_grid = float_grid(rates, fallback: [0.25, 0.35, 0.45, 0.55]).take(4)
      delta_grid =
        if template.driver_type == "category_volume_spike"
          float_grid(deltas, fallback: [0.25, 0.50, 0.75, 1.00]).take(4)
        else
          float_grid(deltas, fallback: [0.05, 0.10, 0.14, 0.18]).take(4)
        end

      z_grid =
        if template.min_z_score.present? || %w[group_outlier_vs_org group_bright_spot_vs_org].include?(template.driver_type)
          float_grid(zscores, fallback: [0.8, 1.0, 1.2, 1.5, 2.0], clamp_0_1: false).take(4)
        else
          [nil]
        end

      grid = []
      win_grid.each do |mw|
        base_grid.each do |mb|
          rate_grid.each do |mr|
            delta_grid.each do |md|
              z_grid.each do |mz|
                grid << {
                  min_window_detections: mw,
                  min_baseline_detections: mb,
                  min_current_rate: mr,
                  min_delta_rate: md,
                  min_z_score: mz
                }
              end
            end
          end
        end
      end
      grid
    end

    def target_rate_for_scope(scope)
      case scope.to_s
      when "user" then @target_fire_rate_user
      when "group" then @target_fire_rate_group
      else 0.0
      end
    end

    def append_sim_rows!(bucket, rows, limit:)
      rows.each do |r|
        break if bucket.length >= limit
        bucket << SimRow.new(
          window_total: r["window_total"].to_i,
          baseline_total: r["baseline_total"].to_i,
          window_negative_rate: r["window_negative_rate"].to_f,
          window_positive_rate: r["window_positive_rate"].to_f,
          delta_negative_rate: r["delta_negative_rate"].to_f,
          delta_positive_rate: r["delta_positive_rate"].to_f,
          relative_change: r["relative_change"],
          org_rate: r["org_rate"],
          group_delta_vs_org: r["group_delta_vs_org"],
          z_score: r["z_score"]
        )
      end
    end

    def int_grid(values, fallback:)
      vals = values.compact.map(&:to_i).reject { |v| v <= 0 }
      return fallback if vals.empty?

      uniq = [
        percentile(vals, 25),
        percentile(vals, 50),
        percentile(vals, 75),
        percentile(vals, 90)
      ].map { |v| [v.to_i, 1].max }.uniq.sort

      uniq.presence || fallback
    end

    def float_grid(values, fallback:, clamp_0_1: true)
      vals = values.compact.map(&:to_f).reject { |v| v.nan? || v.infinite? }
      return fallback if vals.empty?

      uniq = [
        percentile(vals, 50),
        percentile(vals, 75),
        percentile(vals, 90)
      ].map { |v| v.round(3) }.uniq.sort

      uniq = uniq.select { |v| v >= 0.0 && v <= 1.0 } if clamp_0_1
      uniq.presence || fallback
    end

    # ---------------------------
    # Summaries
    # ---------------------------

    def summarize_template_rows(template:, rows:)
      scope = template.subject_scopes.to_s

      rate_field =
        case template.direction
        when "negative" then "window_negative_rate"
        when "positive" then "window_positive_rate"
        else "window_negative_rate"
        end

      delta_field =
        case template.direction
        when "negative" then "delta_negative_rate"
        when "positive" then "delta_positive_rate"
        else "delta_negative_rate"
        end

      window_totals = rows.map { |r| r["window_total"].to_i }
      rates  = rows.map { |r| r[rate_field].to_f }
      deltas = rows.map { |r| r[delta_field].to_f }

      {
        template_key: template.key,
        scope: scope,
        n: rows.size,
        window_total_p50: percentile(window_totals, 50),
        window_total_p75: percentile(window_totals, 75),
        window_total_p90: percentile(window_totals, 90),
        rate_p50: percentile(rates, 50),
        rate_p75: percentile(rates, 75),
        rate_p90: percentile(rates, 90),
        delta_p50: percentile(deltas, 50),
        delta_p75: percentile(deltas, 75),
        delta_p90: percentile(deltas, 90)
      }
    end

    def merge_summaries(group)
      n = group.sum { |g| g[:n].to_i }
      avg = ->(k) { (group.sum { |g| g[k].to_f } / group.size.to_f).round(4) }

      {
        template_key: group.first[:template_key],
        scope: group.first[:scope],
        n: n,
        window_total_p50: avg.call(:window_total_p50),
        window_total_p75: avg.call(:window_total_p75),
        window_total_p90: avg.call(:window_total_p90),
        rate_p50: avg.call(:rate_p50),
        rate_p75: avg.call(:rate_p75),
        rate_p90: avg.call(:rate_p90),
        delta_p50: avg.call(:delta_p50),
        delta_p75: avg.call(:delta_p75),
        delta_p90: avg.call(:delta_p90)
      }
    end

    def percentile(arr, pct)
      return 0.0 if arr.blank?
      sorted = arr.sort
      k = ((pct.to_f / 100.0) * (sorted.length - 1)).round
      sorted[[k, 0].max]
    end
  end
end
