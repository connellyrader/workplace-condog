module Insights
  class ExecSummaryRunner
    POSTED_AT_SQL = Insights::QueryHelpers::POSTED_AT_SQL

    def initialize(workspaces:, reference_time: Time.current, logger: Rails.logger, logit_margin_threshold: ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f)
      @workspaces = Array(workspaces)
      @reference_time = reference_time
      @logger = logger
      @logit_margin_threshold = logit_margin_threshold
    end

    def candidate_for(workspace:, template: nil)
      template ||= InsightTriggerTemplate.enabled.find_by(key: "exec_summary")
      return nil unless template
      return nil unless exec_summary_day?

      build_candidate(workspace: workspace, template: template)
    end

    def run!
      template = InsightTriggerTemplate.enabled.find_by(key: "exec_summary")
      return { created: [], errors: [] } unless template
      return { created: [], errors: [] } unless exec_summary_day?

      created = []
      errors = []

      @workspaces.each do |workspace|
        candidate = build_candidate(workspace: workspace, template: template)
        next unless candidate

        result = Insights::CandidatePersister.new(
          candidates: [candidate],
          reference_time: @reference_time,
          logger: @logger,
          generate_summary: true,
          notify: true
        ).persist!

        created.concat(result.created) if result.respond_to?(:created)
        errors.concat(result.errors) if result.respond_to?(:errors)
      rescue => e
        @logger.error("[Insights::ExecSummaryRunner] workspace=#{workspace.id} error #{e.class}: #{e.message}")
        errors << { workspace: workspace, error: e }
      end

      { created: created, errors: errors }
    end

    private

    def build_candidate(workspace:, template:)
      window_range, baseline_range = window_and_baseline_ranges(template)
      stats = exec_stats(workspace: workspace, template: template, window_range: window_range, baseline_range: baseline_range)
      return nil unless stats

      Insights::Candidate.new(
        trigger_template: template,
        workspace: workspace,
        subject_type: "Workspace",
        subject_id: workspace.id,
        dimension_type: "summary",
        dimension_id: nil,
        window_range: window_range,
        baseline_range: baseline_range,
        stats: stats,
        severity: log1p_safe(stats[:window_total].to_i)
      )
    end

    def exec_stats(workspace:, template:, window_range:, baseline_range:)
      scope = detection_scope(workspace)
      window_scope = in_range(scope, window_range)
      baseline_scope = in_range(scope, baseline_range)

      window_total = window_scope.count
      baseline_total = baseline_scope.count
      window_negative = window_scope.where(polarity: "negative").count
      window_positive = window_scope.where(polarity: "positive").count
      baseline_negative = baseline_scope.where(polarity: "negative").count
      baseline_positive = baseline_scope.where(polarity: "positive").count

      {
        data_present: (window_total.positive? || baseline_total.positive?),
        window_total: window_total,
        baseline_total: baseline_total,
        window_negative_count: window_negative,
        window_positive_count: window_positive,
        baseline_negative_count: baseline_negative,
        baseline_positive_count: baseline_positive,
        window_negative_rate: rate(window_negative, window_total),
        window_positive_rate: rate(window_positive, window_total),
        baseline_negative_rate: rate(baseline_negative, baseline_total),
        baseline_positive_rate: rate(baseline_positive, baseline_total),
        metric_negative_rate_deltas: metric_negative_deltas(window_scope, baseline_scope),
        recent_insights: recent_insights_for(workspace, since: baseline_range.begin),
        logit_margin_min: @logit_margin_threshold,
        confidence_label: "high",
        confidence_volume_strength: 2,
        confidence_spread_strength: 2,
        confidence_effect_strength: 2
      }
    end

    def detection_scope(workspace)
      Detection
        .for_workspace(workspace.id)
        .with_scoring_policy
        .joins(:message)
        .where("#{POSTED_AT_SQL} <= ?", @reference_time)
    end

    def in_range(scope, range)
      scope.where("#{POSTED_AT_SQL} BETWEEN :start_at AND :end_at", start_at: range.begin, end_at: range.end)
    end

    def window_and_baseline_ranges(template)
      window_days   = template.window_days.to_i
      baseline_days = template.baseline_days.to_i
      offset_days   = template.window_offset_days.to_i

      window_end   = (@reference_time - offset_days.days).end_of_day
      window_start = window_end - window_days.days + 1.second

      baseline_end   = window_start - 1.second
      baseline_start = baseline_end - baseline_days.days + 1.second

      [window_start..window_end, baseline_start..baseline_end]
    end

    def metric_negative_deltas(window_scope, baseline_scope)
      win_totals = window_scope.where.not(metric_id: nil).group(:metric_id).count
      win_negs   = window_scope.where.not(metric_id: nil).where(polarity: "negative").group(:metric_id).count
      base_totals = baseline_scope.where.not(metric_id: nil).group(:metric_id).count
      base_negs   = baseline_scope.where.not(metric_id: nil).where(polarity: "negative").group(:metric_id).count

      metric_ids = (win_totals.keys + base_totals.keys).uniq.compact
      metrics = Metric.where(id: metric_ids).index_by(&:id)

      metric_ids.map do |mid|
        w_total = win_totals[mid].to_i
        b_total = base_totals[mid].to_i
        w_neg = win_negs[mid].to_i
        b_neg = base_negs[mid].to_i
        next if w_total.zero? && b_total.zero?

        w_rate = rate(w_neg, w_total)
        b_rate = rate(b_neg, b_total)

        {
          metric_id: mid,
          metric_name: metrics[mid]&.name,
          window_total: w_total,
          baseline_total: b_total,
          window_negative_rate: w_rate,
          baseline_negative_rate: b_rate,
          delta_negative_rate: w_rate - b_rate
        }
      end.compact.sort_by { |h| -h[:delta_negative_rate] }.first(5)
    end

    def recent_insights_for(workspace, since:)
      Insight.where(workspace_id: workspace.id)
             .where.not(kind: "exec_summary")
             .where("created_at >= ?", since)
             .where("created_at <= ?", @reference_time)
             .order(created_at: :desc)
             .limit(25)
             .map do |ins|
        {
          id: ins.id,
          kind: ins.kind,
          subject_type: ins.subject_type,
          subject_id: ins.subject_id,
          metric_id: ins.metric_id,
          polarity: ins.polarity,
          severity: ins.severity,
          summary_title: ins.summary_title,
          summary_body: ins.summary_body,
          created_at: ins.created_at
        }
      end
    end

    def rate(count, total)
      return 0.0 if total.to_i <= 0
      count.to_f / total.to_f
    end

    def log1p_safe(value)
      if Math.respond_to?(:log1p)
        Math.log1p(value.to_f)
      else
        Math.log(1 + value.to_f)
      end
    end

    def exec_summary_day?
      day = @reference_time.to_date.day
      day == 1 || day == 15
    end
  end
end
