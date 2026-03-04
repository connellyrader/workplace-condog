module Insights
  module Studio
    class DailyReplayRunner
      Result = Struct.new(:run, :candidates, :primary_candidates, :selection, :template_stats, keyword_init: true)

      def initialize(workspace:, start_date:, end_date:, baseline_mode:, logit_margin_min:, fdr_q_threshold: nil, mode: "dry_run", notify: false, logger: Rails.logger, run_record: nil)
        @workspace = workspace
        @start_date = start_date&.to_date
        @end_date = end_date&.to_date
        @baseline_mode = baseline_mode.presence || "trailing"
        @logit_margin_min = logit_margin_min.to_f
        @fdr_q_threshold = fdr_q_threshold
        @mode = "dry_run"
        @notify = false
        @logger = logger
        @run_record = run_record
      end

      def run!
        run_record = @run_record
        timings = nil
        raise "INSIGHTS_V2_ENABLED is false" unless Insights::FeatureFlags.v2_enabled?
        raise ArgumentError, "workspace required" unless workspace
        raise ArgumentError, "start_date required" unless start_date
        raise ArgumentError, "end_date required" unless end_date
        raise ArgumentError, "end_date must be >= start_date" if end_date < start_date

        run_record = run_record || InsightPipelineRun.create!(
          workspace: workspace,
          snapshot_at: end_date.end_of_day,
          mode: mode,
          status: "running",
          logit_margin_min: logit_margin_min,
          timings: {},
          error_payload: {}
        )
        run_record.update!(status: "running") unless run_record.status == "running"

        timings = base_timings

        update_progress!(run_record, timings, stage: "rollups", progress: 0.05)
        rollups_result = Insights::Pipeline::Rollups.ensure_rollups!(
          workspace: workspace,
          snapshot_at: end_date.end_of_day,
          baseline_mode: baseline_mode,
          logit_margin_min: logit_margin_min,
          range_days: range_days,
          logger: logger
        )

        ledger = []
        previous_signatures = nil
        deliverable_candidates = []
        total_primary = 0
        total_accepted = 0
        template_stats = {}

        days = (start_date..end_date).to_a
        days.each_with_index do |day, idx|
          snapshot_at = day.end_of_day
          update_progress!(run_record, timings, stage: "replay", progress: progress_for(idx, days.length))

          day_result = run_day(snapshot_at: snapshot_at, ledger: ledger, previous_signatures: previous_signatures)

          total_primary += day_result.primary_candidates.size
          accepted_primary = day_result.selection.accepted.select { |c| c.trigger_template&.primary? }
          total_accepted += accepted_primary.size

          day_deliverable = accepted_primary.select { |c| deliverable_candidate?(c) }
          deliverable_candidates.concat(day_deliverable)

          ledger.concat(build_virtual_insights(day_deliverable, snapshot_at))
          previous_signatures = day_result.primary_candidates.map { |c| candidate_signature(c) }.uniq

          merge_template_stats!(template_stats, day_result.template_stats || {})
        end

        finalize_template_stats!(template_stats)

        selection = Insights::CandidateSelector::Result.new(accepted: deliverable_candidates, rejected: [])

        run_record.update!(
          status: "ok",
          candidates_total: total_primary,
          candidates_primary: total_primary,
          accepted_primary: total_accepted,
          persisted_count: 0,
          delivered: 0,
          timings: timings.merge(stage: "complete", progress: 1.0, rollups: rollups_result&.to_h)
        )

        Result.new(
          run: run_record,
          candidates: deliverable_candidates,
          primary_candidates: deliverable_candidates,
          selection: selection,
          template_stats: template_stats
        )
      rescue => e
        run_record&.update!(
          status: "error",
          timings: timings&.merge(stage: "error", progress: 1.0) || {},
          error_payload: {
            message: e.message,
            backtrace: Array(e.backtrace).first(20)
          }
        )
        raise
      end

      private

      attr_reader :workspace, :start_date, :end_date, :baseline_mode, :logit_margin_min, :fdr_q_threshold, :mode, :notify, :logger

      def range_days
        (end_date - start_date).to_i + 1
      end

      def base_timings
        {
          baseline_mode: baseline_mode,
          range_days: range_days,
          fdr_q_threshold: fdr_q_threshold,
          start_date: start_date.to_s,
          end_date: end_date.to_s,
          stage: "queued",
          progress: 0.0
        }
      end

      def progress_for(index, total)
        return 0.1 if total <= 0
        step = 0.85 * ((index + 1).to_f / total.to_f)
        0.1 + step
      end

      def update_progress!(run_record, timings, stage:, progress:)
        timings[:stage] = stage
        timings[:progress] = progress
        run_record.update!(timings: timings, status: "running")
      rescue => e
        logger.warn("[Insights::Studio::DailyReplayRunner] progress update failed #{e.class}: #{e.message}")
      end

      def run_day(snapshot_at:, ledger:, previous_signatures:)
        null_run = Insights::Pipeline::NullRunRecord.new(
          workspace: workspace,
          snapshot_at: snapshot_at,
          mode: "dry_run",
          status: "running",
          logit_margin_min: logit_margin_min
        )

        runner = Insights::Pipeline::Runner.new(
          workspace: workspace,
          snapshot_at: snapshot_at,
          baseline_mode: baseline_mode,
          logit_margin_min: logit_margin_min,
          range_days: 1,
          fdr_q_threshold: fdr_q_threshold,
          mode: "dry_run",
          notify: false,
          logger: logger,
          run_record: null_run,
          virtual_insights: ledger,
          as_of: snapshot_at,
          previous_signatures: previous_signatures
        )

        runner.run!
      end

      def deliverable_candidate?(candidate)
        stats = (candidate.stats || {}).with_indifferent_access
        stats[:deliverable] == true
      end

      def candidate_signature(candidate)
        [
          candidate.trigger_template&.id,
          candidate.subject_type.to_s,
          candidate.subject_id,
          candidate.dimension_type.to_s,
          candidate.dimension_id
        ].join(":")
      end

      def build_virtual_insights(candidates, snapshot_at)
        candidates.filter_map do |candidate|
          template = candidate.trigger_template
          next unless template

          created_at = candidate_reference_time(candidate, snapshot_at)
          next_eligible_at =
            if template.cooldown_days.to_i.positive?
              created_at + template.cooldown_days.to_i.days
            else
              nil
            end

          VirtualInsight.new(
            workspace_id: candidate.workspace.id,
            subject_type: candidate.subject_type,
            subject_id: candidate.subject_id,
            trigger_template_id: template.id,
            created_at: created_at,
            next_eligible_at: next_eligible_at
          )
        end
      end

      def candidate_reference_time(candidate, fallback)
        stats = (candidate.stats || {}).with_indifferent_access
        raw = stats[:snapshot_at]
        time =
          if raw.present?
            raw.is_a?(Time) ? raw : (Time.zone.parse(raw.to_s) rescue nil)
          end
        time ||= candidate.window_range&.end
        time ||= fallback
        time
      end

      def merge_template_stats!(accumulator, stats)
        stats.each do |template_id, row|
          next unless row
          entry = (accumulator[template_id] ||= { fired_count: 0, total_candidates: 0, fire_rate: 0.0, last_fired_at: nil, reject_counts: Hash.new(0) })
          entry[:fired_count] += row[:fired_count].to_i
          entry[:total_candidates] += row[:total_candidates].to_i
          entry[:last_fired_at] = [entry[:last_fired_at], row[:last_fired_at]].compact.max
          (row[:reject_counts] || {}).each do |reason, count|
            entry[:reject_counts][reason.to_s] += count.to_i
          end
        end
      end

      def finalize_template_stats!(template_stats)
        template_stats.each_value do |row|
          total = row[:total_candidates].to_i
          fired = row[:fired_count].to_i
          row[:fire_rate] = total.positive? ? (fired.to_f / total.to_f) : 0.0
        end
      end

      VirtualInsight = Struct.new(
        :workspace_id,
        :subject_type,
        :subject_id,
        :trigger_template_id,
        :created_at,
        :next_eligible_at,
        keyword_init: true
      )
    end
  end
end
