module Insights
  module Pipeline
    class Runner
      Result = Struct.new(:run, :candidates, :primary_candidates, :selection, :persist_result, :template_stats, keyword_init: true)

      def initialize(workspace:, snapshot_at: Time.current, mode: "dry_run", baseline_mode: "trailing", logit_margin_min: nil, range_days: 1, notify: true, logger: Rails.logger, run_record: nil, fdr_q_threshold: nil, virtual_insights: nil, as_of: nil, previous_signatures: nil)
        @workspace = workspace
        @snapshot_at = snapshot_at
        @mode = mode.to_s.presence || "dry_run"
        @baseline_mode = baseline_mode.presence || "trailing"
        @logit_margin_min = (logit_margin_min.presence || ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")).to_f
        @range_days = range_days.to_i
        @notify = notify
        @logger = logger
        @run_record = run_record
        @fdr_q_threshold = fdr_q_threshold
        @virtual_insights = Array(virtual_insights)
        @as_of = as_of
        @previous_signatures = previous_signatures
      end

      def run!
        raise "INSIGHTS_V2_ENABLED is false" unless Insights::FeatureFlags.v2_enabled?
        raise ArgumentError, "workspace required" unless workspace

        timings = { baseline_mode: baseline_mode, range_days: range_days, fdr_q_threshold: fdr_q_threshold }
        persist_result = nil

        run_record = @run_record || InsightPipelineRun.create!(
          workspace: workspace,
          snapshot_at: snapshot_at,
          mode: mode,
          status: "running",
          logit_margin_min: logit_margin_min,
          timings: {},
          error_payload: {}
        )
        run_record.update!(status: "running") unless run_record.status == "running"

        rollups_result = nil
        candidates = []
        primary_candidates = []
        selection = Insights::CandidateSelector::Result.new(accepted: [], rejected: [])
        template_stats = {}
        daily_primary_candidates = {}
        original_snapshot_at = snapshot_at
        effective_snapshot_at = snapshot_at
        snapshot_times = []

        begin
          update_progress!(run_record, timings, stage: "rollups", progress: 0.15)
          timings[:rollups_ms] = measure_ms do
            rollups_result = Rollups.ensure_rollups!(
              workspace: workspace,
              snapshot_at: effective_snapshot_at,
              baseline_mode: baseline_mode,
              logit_margin_min: logit_margin_min,
              range_days: range_days,
              logger: logger
            )
          end

          guardrail = apply_completeness_guardrail(snapshot_at: effective_snapshot_at)
          effective_snapshot_at = guardrail[:snapshot_at]
          timings[:completeness] = guardrail[:metrics]
          if effective_snapshot_at != run_record.snapshot_at
            run_record.update!(snapshot_at: effective_snapshot_at)
          end

          snapshot_times = snapshot_times_for_range(snapshot_at: effective_snapshot_at)

          unless InsightDetectionRollup.where(workspace_id: workspace.id, logit_margin_min: logit_margin_min).exists?
            logger.warn("[Insights::Pipeline::Runner] no rollups found for workspace=#{workspace.id} logit=#{logit_margin_min}")
          end

          update_progress!(run_record, timings, stage: "evaluate", progress: 0.45)
          timings[:evaluate_ms] = measure_ms do
            snapshot_times.each do |snap_time|
              evaluation = Evaluator.new(
                workspace: workspace,
                snapshot_at: snap_time,
                baseline_mode: baseline_mode,
                logit_margin_min: logit_margin_min,
                logger: logger
              ).run!

              candidates.concat(evaluation.candidates)
              primary_candidates.concat(evaluation.primary_candidates)
              daily_primary_candidates[snap_time] = evaluation.primary_candidates

              evaluation.template_stats&.each do |template_id, stats|
                row = (template_stats[template_id] ||= { fired_count: 0, total_candidates: 0, fire_rate: 0.0, last_fired_at: nil, reject_counts: Hash.new(0) })
                row[:fired_count] += stats[:fired_count].to_i
                row[:total_candidates] += stats[:total_candidates].to_i
                last_fired = stats[:last_fired_at]
                row[:last_fired_at] = [row[:last_fired_at], last_fired].compact.max
                (stats[:reject_counts] || {}).each do |reason, count|
                  row[:reject_counts][reason.to_s] += count.to_i
                end
              end
            end
          end

          exec_reference_time = original_snapshot_at
          exec_candidate = Insights::ExecSummaryRunner.new(
            workspaces: [workspace],
            reference_time: exec_reference_time,
            logit_margin_threshold: logit_margin_min,
            logger: logger
          ).candidate_for(workspace: workspace)

          if exec_candidate
            exec_candidate.stats = (exec_candidate.stats || {}).merge(snapshot_at: exec_reference_time)
            candidates << exec_candidate
            primary_candidates << exec_candidate
            template_stats[exec_candidate.trigger_template.id] ||= { fired_count: 0, total_candidates: 0, fire_rate: 0.0, last_fired_at: nil }
            template_stats[exec_candidate.trigger_template.id][:fired_count] += 1
            template_stats[exec_candidate.trigger_template.id][:total_candidates] += 1
            template_stats[exec_candidate.trigger_template.id][:last_fired_at] = exec_reference_time
            daily_primary_candidates[exec_reference_time] ||= []
            daily_primary_candidates[exec_reference_time] << exec_candidate
          end

          update_progress!(run_record, timings, stage: "drivers", progress: 0.65)
          timings[:attach_ms] = measure_ms do
            DriverComputer.new(
              workspace: workspace,
              logit_margin_min: logit_margin_min,
              primary_candidates: primary_candidates,
              logger: logger
            ).attach!
          end

          primary_candidates = dedupe_candidates(primary_candidates)
          candidates = primary_candidates
          daily_primary_candidates = group_candidates_by_snapshot(primary_candidates, fallback_snapshot: effective_snapshot_at)

          fdr_rejections = []
          fdr_threshold = effective_fdr_q_threshold
          timings[:fdr] = { threshold: fdr_threshold }
          if fdr_threshold.positive?
            fdr_candidates = primary_candidates.reject { |c| c.trigger_template&.key.to_s == "exec_summary" }
            fdr_result = Insights::CandidateFdrGate.new(candidates: fdr_candidates, q_threshold: fdr_threshold).apply!
            fdr_rejections = fdr_result.rejected
            timings[:fdr][:filtered] = fdr_rejections.size
          end

          previous_signatures = @previous_signatures || previous_candidate_signatures(run_record)
          primary_candidates.each do |candidate|
            mark_delivery_status(candidate, deliverable: true) if candidate.trigger_template&.key.to_s == "exec_summary"
            deliverable_rejection_reason(candidate, previous_signatures: previous_signatures)
          end

          update_progress!(run_record, timings, stage: "select", progress: 0.8)
          timings[:select_ms] = measure_ms do
            accepted = []
            rejected = []
            daily_primary_candidates.each do |snap_time, day_candidates|
              next if day_candidates.blank?
              result = Insights::CandidateSelector.new(
                candidates: day_candidates,
                reference_time: snap_time,
                virtual_insights: virtual_insights,
                as_of: as_of
              ).select!
              accepted.concat(result.accepted)
              rejected.concat(result.rejected)
            end
            selection = Insights::CandidateSelector::Result.new(accepted: accepted, rejected: rejected)
          end

          timings[:quality] = build_quality_metrics(primary_candidates: primary_candidates, selection: selection, template_stats: template_stats)

          template_stats.each_value do |row|
            total = row[:total_candidates].to_i
            fired = row[:fired_count].to_i
            row[:fire_rate] = total.positive? ? (fired.to_f / total.to_f) : 0.0
          end

          accepted_primary = selection.accepted.select { |c| c.trigger_template&.primary? }
          deliverable_primary = accepted_primary.select { |c| deliverable_candidate?(c) }

          if mode == "persist"
            update_progress!(run_record, timings, stage: "persist", progress: 0.92)
            timings[:persist_ms] = measure_ms do
              persist_result = Insights::CandidatePersister.new(
                candidates: deliverable_primary,
                reference_time: effective_snapshot_at,
                logger: logger,
                generate_summary: true,
                notify: notify
              ).persist!
            end
          end

          run_record.update!(
            status: "ok",
            candidates_total: candidates.size,
            candidates_primary: primary_candidates.size,
            accepted_primary: accepted_primary.size,
            persisted_count: persist_result&.created&.size.to_i,
            delivered: persist_result&.created&.size.to_i,
            timings: timings.merge(stage: "complete", progress: 1.0, candidate_signatures: primary_candidates.map { |c| candidate_signature(c) }.uniq),
            error_payload: {}
          )
        rescue => e
          run_record.update!(
            status: "error",
            timings: timings.merge(stage: "error", progress: 1.0),
            error_payload: {
              message: e.message,
              backtrace: Array(e.backtrace).first(20),
              rollups: rollups_result&.to_h
            }
          )
          raise
        end

        Result.new(
          run: run_record,
          candidates: candidates,
          primary_candidates: primary_candidates,
          selection: selection,
          persist_result: persist_result,
          template_stats: template_stats
        )
      end

      private

      attr_reader :workspace, :snapshot_at, :mode, :baseline_mode, :logit_margin_min, :range_days, :notify, :logger, :fdr_q_threshold, :virtual_insights, :as_of

      def effective_fdr_q_threshold
        return fdr_q_threshold.to_f if fdr_q_threshold.present?
        ENV.fetch("INSIGHTS_FDR_Q_THRESHOLD", "0.1").to_f
      end

      def update_progress!(run_record, timings, stage:, progress:)
        timings[:stage] = stage
        timings[:progress] = progress
        existing = run_record.timings || {}
        preview_map = existing["preview_summaries"] || existing[:preview_summaries]
        if preview_map && !(timings.key?(:preview_summaries) || timings.key?("preview_summaries"))
          timings[:preview_summaries] = preview_map
          timings["preview_summaries"] = preview_map
        end
        run_record.update!(timings: timings, status: "running")
      rescue => e
        logger.warn("[Insights::Pipeline::Runner] progress update failed #{e.class}: #{e.message}")
      end

      def measure_ms
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0).round(1)
      end

      def snapshot_times_for_range(snapshot_at: self.snapshot_at)
        days = range_days.to_i
        days = 1 if days <= 0
        start_time = snapshot_at - (days - 1).days
        (0...days).map { |offset| start_time + offset.days }
      end

      def apply_completeness_guardrail(snapshot_at:)
        threshold = ENV.fetch("INSIGHTS_SNAPSHOT_COMPLETENESS_THRESHOLD", "0.7").to_f
        scope = InsightDetectionRollup.where(workspace_id: workspace.id, logit_margin_min: logit_margin_min)
        target_date = snapshot_at.to_date
        prior_start = target_date - 7.days
        prior_end = target_date - 1.day
        prior_counts = scope.where(posted_on: prior_start..prior_end).group(:posted_on).sum(:total_count)

        if prior_counts.size < 7
          return {
            snapshot_at: snapshot_at,
            metrics: {
              status: "unknown",
              threshold: threshold,
              reason: "insufficient_history"
            }
          }
        end

        median_total = median(prior_counts.values)
        return {
          snapshot_at: snapshot_at,
          metrics: {
            status: "unknown",
            threshold: threshold,
            reason: "median_zero"
          }
        } if median_total.to_f <= 0

        today_total = scope.where(posted_on: target_date).sum(:total_count).to_i
        ratio = today_total.to_f / median_total.to_f

        if ratio < threshold
          adjusted = (target_date - 1.day).end_of_day
          return {
            snapshot_at: adjusted,
            metrics: {
              status: "shifted",
              threshold: threshold,
              ratio: ratio,
              today_total: today_total,
              median_total: median_total,
              original_snapshot_at: snapshot_at.iso8601,
              adjusted_snapshot_at: adjusted.iso8601
            }
          }
        end

        {
          snapshot_at: snapshot_at,
          metrics: {
            status: "ok",
            threshold: threshold,
            ratio: ratio,
            today_total: today_total,
            median_total: median_total
          }
        }
      end

      def median(values)
        nums = Array(values).compact.map(&:to_f).sort
        return 0.0 if nums.empty?
        mid = nums.length / 2
        if nums.length.odd?
          nums[mid]
        else
          (nums[mid - 1] + nums[mid]) / 2.0
        end
      end

      def build_quality_metrics(primary_candidates:, selection:, template_stats:)
        window_days = Array(primary_candidates).filter_map do |candidate|
          stats = (candidate.stats || {}).with_indifferent_access
          stats[:effective_window_days]
        end

        filter_counts = Hash.new(0)
        Array(selection&.rejected).each do |entry|
          reason = entry[:reason].to_s.presence || "unknown"
          filter_counts[reason] += 1
        end

        Array(primary_candidates).each do |candidate|
          stats = (candidate.stats || {}).with_indifferent_access
          reason = stats[:delivery_reason].to_s.presence
          next unless reason

          filter_counts["delivery_#{reason}"] += 1
        end

        Array(template_stats&.values).each do |stats|
          next unless stats
          (stats[:reject_counts] || {}).each do |reason, count|
            key = reason.to_s.presence || "unknown"
            filter_counts[key] += count.to_i
          end
        end

        {
          median_effective_window_days: median(window_days),
          filter_counts: filter_counts
        }
      end

      def deliverable_rejection_reason(candidate, previous_signatures:)
        return nil if candidate.trigger_template&.key.to_s == "exec_summary"

        fdr_reason = fdr_rejection_reason(candidate)
        if fdr_reason
          mark_delivery_status(candidate, deliverable: false, reason: fdr_reason)
          return fdr_reason
        end

        effect_reason = effect_gate_reason(candidate)
        if effect_reason
          mark_delivery_status(candidate, deliverable: false, reason: effect_reason)
          return effect_reason
        end

        label = confidence_label(candidate)
        if label == "high"
          mark_delivery_status(candidate, deliverable: true)
          return nil
        end

        if label == "medium"
          signature = candidate_signature(candidate)
          recurrence_met = previous_signatures.include?(signature)
          mark_delivery_status(candidate, deliverable: recurrence_met, reason: (recurrence_met ? nil : :needs_recurrence), recurrence_met: recurrence_met)
          return recurrence_met ? nil : :needs_recurrence
        end

        if fdr_skipped_for?(candidate)
          stats = (candidate.stats || {}).with_indifferent_access
          stats[:delivery_override] = "low_confidence_fdr_skipped"
          candidate.stats = stats
          mark_delivery_status(candidate, deliverable: true)
          return nil
        end

        mark_delivery_status(candidate, deliverable: false, reason: :low_confidence)
        :low_confidence
      end

      def fdr_rejection_reason(candidate)
        stats = (candidate.stats || {}).with_indifferent_access
        applicable = stats[:fdr_applicable]
        return nil unless applicable

        pass = stats[:fdr_pass]
        return nil if pass.nil? || pass == true

        :fdr
      end

      def fdr_skipped_for?(candidate)
        stats = (candidate.stats || {}).with_indifferent_access
        stats[:fdr_applicable] == false
      end

      def mark_delivery_status(candidate, deliverable:, reason: nil, recurrence_met: nil)
        stats = (candidate.stats || {}).with_indifferent_access
        stats[:deliverable] = deliverable
        stats[:delivery_reason] = reason.to_s if reason
        stats[:recurrence_met] = recurrence_met unless recurrence_met.nil?
        candidate.stats = stats
      end

      def effect_gate_reason(candidate)
        stats = (candidate.stats || {}).with_indifferent_access
        reasons = Array(stats[:effect_gate_reasons] || stats["effect_gate_reasons"]).map(&:to_sym)
        return nil if reasons.empty?

        reasons.first
      end

      def confidence_label(candidate)
        stats = (candidate.stats || {}).with_indifferent_access
        label = stats[:confidence_label].to_s
        label = "low" if label.blank?
        label
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

      def previous_candidate_signatures(run_record)
        scope = InsightPipelineRun
                .where(workspace_id: workspace.id, status: "ok")
                .where.not(id: run_record.id)
        scope = scope.where(InsightPipelineRun.arel_table[:created_at].lteq(as_of)) if as_of
        previous = scope.order(snapshot_at: :desc).first
        Array(previous&.timings&.dig("candidate_signatures"))
      end

      def deliverable_candidate?(candidate)
        stats = (candidate.stats || {}).with_indifferent_access
        stats[:deliverable] == true
      end

      def dedupe_candidates(candidates)
        grouped = candidates.group_by { |candidate| candidate_signature(candidate) }
        grouped.values.map do |group|
          group.max_by do |candidate|
            snapshot = candidate_snapshot_time(candidate)
            [snapshot.to_i, candidate.severity.to_f]
          end
        end
      end

      def group_candidates_by_snapshot(candidates, fallback_snapshot:)
        candidates.group_by { |candidate| candidate_snapshot_time(candidate) || fallback_snapshot }
      end

      def candidate_snapshot_time(candidate)
        stats = (candidate.stats || {}).with_indifferent_access
        raw = stats[:snapshot_at] || stats["snapshot_at"]
        time = parse_snapshot_time(raw)
        return time if time
        return candidate.window_range&.end if candidate.window_range

        nil
      end

      def parse_snapshot_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return nil if value.blank?
        Time.zone.parse(value.to_s)
      rescue
        nil
      end
    end
  end
end

