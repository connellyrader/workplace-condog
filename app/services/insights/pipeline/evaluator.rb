module Insights
  module Pipeline
    class Evaluator
      Result = Struct.new(:candidates, :primary_candidates, :template_stats, keyword_init: true)

      def initialize(workspace:, snapshot_at:, baseline_mode:, logit_margin_min:, logger: Rails.logger)
        @workspace = workspace
        @snapshot_at = snapshot_at
        @baseline_mode = baseline_mode.presence || "trailing"
        @logit_margin_min = logit_margin_min.to_f
        @logger = logger
      end

      def run!
        candidates = []
        primary_candidates = []
        template_stats = {}

        templates = InsightTriggerTemplate.enabled.order(:key)
        overrides = workspace_overrides

        templates.each do |template|
          override = overrides[template.id]
          next if override && !override.enabled
          next unless template.primary?
          next if template.driver_type.to_s == "exec_summary"

          simulator_class = simulator_for(template)
          unless simulator_class
            logger.warn("[Insights::Pipeline::Evaluator] unsupported driver_type=#{template.driver_type} template=#{template.key}")
            next
          end

          overrides_hash = (override&.overrides || {}).to_h
          overrides_hash = overrides_hash.merge(logit_margin_min: logit_margin_min)

          simulator = simulator_class.new(
            template: template,
            workspace: workspace,
            snapshot_at: snapshot_at,
            baseline_mode: baseline_mode,
            overrides: overrides_hash,
            logger: logger
          )

          evaluation = simulator.qualifying_stats
          fired = Array(evaluation[:fired])
          summary = (evaluation[:summary] || {}).with_indifferent_access

          template_stats[template.id] = {
            fired_count: fired.size,
            total_candidates: summary[:total_candidates].to_i,
            fire_rate: summary[:fire_rate].to_f,
            last_fired_at: fired.any? ? snapshot_at : nil,
            reject_counts: summary[:reject_counts] || {}
          }

          fired.each do |stats|
            stats = stats.merge(snapshot_at: snapshot_at, logit_margin_min: logit_margin_min)
            candidate = build_candidate(
              template: template,
              stats: stats,
              window_range: evaluation[:window_range],
              baseline_range: evaluation[:baseline_range]
            )
            candidates << candidate
            primary_candidates << candidate
          end
        end

        Result.new(
          candidates: candidates,
          primary_candidates: primary_candidates,
          template_stats: template_stats
        )
      end

      private

      attr_reader :workspace, :snapshot_at, :baseline_mode, :logit_margin_min, :logger

      def workspace_overrides
        WorkspaceInsightTemplateOverride.where(workspace_id: workspace.id).index_by(&:trigger_template_id)
      end

      def simulator_for(template)
        Insights::TriggerSimulation::DRIVER_SIMULATORS[template.driver_type.to_s]
      end

      def build_candidate(template:, stats:, window_range:, baseline_range:)
        severity = Insights::Severity.score(template: template, stats: stats)
        stats = stats.merge(severity: severity)

        window_range = stats[:window_range] || stats["window_range"] || window_range
        baseline_range = stats[:baseline_range] || stats["baseline_range"] || baseline_range

        Insights::Candidate.new(
          trigger_template: template,
          workspace: workspace,
          subject_type: stats[:subject_type],
          subject_id: stats[:subject_id],
          dimension_type: stats[:dimension_type],
          dimension_id: stats[:dimension_id],
          window_range: window_range,
          baseline_range: baseline_range,
          stats: stats,
          severity: severity,
          detection_id: nil
        )
      end
    end
  end
end
