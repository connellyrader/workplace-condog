module Insights
  module Pipeline
    class Rollups
      Result = Struct.new(:start_date, :end_date, :built, keyword_init: true)

      def self.ensure_rollups!(workspace:, snapshot_at:, baseline_mode:, logit_margin_min:, range_days: 1, logger: Rails.logger)
        new(
          workspace: workspace,
          snapshot_at: snapshot_at,
          baseline_mode: baseline_mode,
          logit_margin_min: logit_margin_min,
          range_days: range_days,
          logger: logger
        ).ensure_rollups!
      end

      def self.rollup_range_for(workspace:, snapshot_at:, baseline_mode:, templates: nil, range_days: 1)
        templates ||= InsightTriggerTemplate.enabled.order(:key)
        overrides = WorkspaceInsightTemplateOverride.where(workspace_id: workspace.id).index_by(&:trigger_template_id)
        range_days = range_days.to_i
        range_days = 1 if range_days <= 0
        range_end_date = snapshot_at.to_date
        range_start_date = range_end_date - (range_days - 1).days
        snapshot_dates = (range_start_date..range_end_date).to_a

        ranges = []

        snapshot_dates.each do |snap_date|
          snapshot_time = snap_date.end_of_day

          templates.each do |template|
            override = overrides[template.id]
            next if override && !override.enabled
            next unless template.primary?
            next if template.driver_type.to_s == "exec_summary"

            window_days = fetch_override_int(override, "window_days", template.window_days)
            window_days = 14 if window_days <= 0
            baseline_days = fetch_override_int(override, "baseline_days", template.baseline_days)
            baseline_days = window_days if baseline_days <= 0
            window_offset_days = fetch_override_int(override, "window_offset_days", template.window_offset_days)
            baseline_days_in_use = baseline_mode.to_s == "previous_period" ? window_days : baseline_days

            window_end = (snapshot_time - window_offset_days.days).end_of_day
            window_start = window_end - window_days.days + 1.second
            baseline_end = window_start - 1.second
            baseline_start = baseline_end - baseline_days_in_use.days + 1.second

            ranges << { start: baseline_start, end: window_end }
          end
        end

        if ranges.empty?
          return [range_start_date, range_end_date]
        end

        start_at = ranges.map { |r| r[:start] }.min
        end_at = ranges.map { |r| r[:end] }.max
        [start_at.to_date, end_at.to_date]
      end

      def self.fetch_override_int(override, key, fallback)
        raw = override&.overrides&.[](key.to_s)
        raw = override&.overrides&.[](key.to_sym) if raw.nil?
        raw = fallback if raw.nil?
        raw.to_i
      end

      def initialize(workspace:, snapshot_at:, baseline_mode:, logit_margin_min:, range_days: 1, logger: Rails.logger)
        @workspace = workspace
        @snapshot_at = snapshot_at
        @baseline_mode = baseline_mode.presence || "trailing"
        @logit_margin_min = logit_margin_min.to_f
        @range_days = range_days.to_i
        @logger = logger
      end

      def ensure_rollups!
        range_start, range_end = self.class.rollup_range_for(
          workspace: workspace,
          snapshot_at: snapshot_at,
          baseline_mode: baseline_mode,
          range_days: range_days
        )
        end_date = range_end
        scope = InsightDetectionRollup.where(workspace_id: workspace.id, logit_margin_min: logit_margin_min)
        existing_start = scope.minimum(:posted_on)
        existing_end = scope.maximum(:posted_on)

        if existing_start && existing_end && existing_start <= range_start && existing_end >= end_date
          return Result.new(start_date: range_start, end_date: end_date, built: false)
        end

        start_date =
          if existing_start.nil?
            range_start
          elsif existing_start > range_start
            range_start
          elsif existing_end && existing_end < end_date
            existing_end + 1.day
          else
            range_start
          end

        if start_date && start_date > end_date
          return Result.new(start_date: start_date, end_date: end_date, built: false)
        end

        builder = Insights::RollupBuilder.new(
          workspace: workspace,
          logit_margin_min: logit_margin_min,
          start_date: start_date,
          end_date: end_date,
          logger: logger
        )
        builder.run!

        Result.new(start_date: start_date, end_date: end_date, built: true)
      end

      private

      attr_reader :workspace, :snapshot_at, :baseline_mode, :logit_margin_min, :logger, :range_days
    end
  end
end
