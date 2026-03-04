module Insights
  module TriggerSimulators
    class GroupOutlierVsOrg < Base
      def qualifying_stats
        window_range, baseline_range = window_and_baseline_ranges
        rows = aggregate_rows(
          window_range: window_range,
          baseline_range: baseline_range,
          subject_types: ["Group", "Workspace"],
          dimension_types: dimension_types_for(dimension_type)
        )

        workspace_index = build_workspace_index(rows)

        fired = []
        total_seen = 0
        eligible_count = 0
        rejects = Hash.new(0)

        rows.select { |r| r.subject_type == "Group" }.each do |row|
          stats = build_stats(row, workspace_index: workspace_index)
          next unless stats

          total_seen += 1
          eligible_count += 1 if stats[:eligible]
          if stats[:qualifies]
            fired << stats
          else
            Array(stats[:reject_reasons]).each { |r| rejects[r] += 1 }
          end
        end

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

      def run!
        window_range, baseline_range = window_and_baseline_ranges
        rows = aggregate_rows(
          window_range: window_range,
          baseline_range: baseline_range,
          subject_types: ["Group", "Workspace"],
          dimension_types: dimension_types_for(dimension_type)
        )

        workspace_index = build_workspace_index(rows)

        fired = []
        total_seen = 0
        eligible_count = 0
        rejects = Hash.new(0)

        rows.select { |r| r.subject_type == "Group" }.each do |row|
          stats = build_stats(row, workspace_index: workspace_index)
          next unless stats

          total_seen += 1
          eligible_count += 1 if stats[:eligible]
          if stats[:qualifies]
            fired << stats
          else
            Array(stats[:reject_reasons]).each { |r| rejects[r] += 1 }
          end
        end

        result(
          params: params_with_ranges(window_range: window_range, baseline_range: baseline_range),
          fired: fired,
          total_seen: total_seen,
          eligible_count: eligible_count,
          rejects: rejects
        )
      end

      private

      def build_workspace_index(rows)
        rows
          .select { |r| r.subject_type == "Workspace" }
          .index_by { |r| [r.dimension_type, r.dimension_id, r.metric_id] }
      end

      def build_stats(row, workspace_index:)
        window_total = row.window_total.to_i
        baseline_total = row.baseline_total.to_i
        min_window = dynamic_min_window_for(row, baseline_total: baseline_total)
        min_baseline = dynamic_min_baseline_for(row)
        tiny_sample = tiny_sample?(window_total, baseline_total)
        volume_ok = window_total >= min_window && baseline_total >= min_baseline && !tiny_sample

        workspace_row = workspace_index[[row.dimension_type, row.dimension_id, row.metric_id]]
        return nil unless workspace_row

        workspace_window_total = workspace_row.window_total.to_i
        return nil if workspace_window_total <= 0

        window_positive = row.window_positive.to_i
        window_negative = row.window_negative.to_i
        workspace_positive = workspace_row.window_positive.to_i
        workspace_negative = workspace_row.window_negative.to_i

        window_pos_rate = smoothed_rate(window_positive, window_total, negative: false)
        window_neg_rate = smoothed_rate(window_negative, window_total, negative: true)
        workspace_pos_rate = smoothed_rate(workspace_positive, workspace_window_total, negative: false)
        workspace_neg_rate = smoothed_rate(workspace_negative, workspace_window_total, negative: true)

        current_rate, compare_rate =
          case direction.to_s
          when "positive"
            [window_pos_rate, workspace_pos_rate]
          when "negative"
            [window_neg_rate, workspace_neg_rate]
          else
            # pick the dominant polarity for gap comparison
            if (window_neg_rate - workspace_neg_rate) >= (window_pos_rate - workspace_pos_rate)
              [window_neg_rate, workspace_neg_rate]
            else
              [window_pos_rate, workspace_pos_rate]
            end
          end

        delta_rate = current_rate - compare_rate
        qualifies = true
        reject_reasons = []
        if min_current_rate && current_rate < min_current_rate.to_f
          qualifies = false
          reject_reasons << :min_current_rate
        end
        if min_delta_rate && delta_rate < min_delta_rate.to_f
          qualifies = false
          reject_reasons << :min_delta_rate
        end

        z_score = compute_z_score(
          window_rate: current_rate,
          window_total: window_total,
          compare_rate: compare_rate,
          compare_total: workspace_window_total
        )
        z_gate_passed = min_z_score ? z_score >= min_z_score.to_f : nil

        effect_stats = compute_effect_stats(
          window_total: window_total,
          window_positive: window_positive,
          window_negative: window_negative,
          baseline_total: workspace_window_total,
          baseline_positive: workspace_positive,
          baseline_negative: workspace_negative,
          window_pos_rate: window_pos_rate,
          window_neg_rate: window_neg_rate,
          baseline_pos_rate: workspace_pos_rate,
          baseline_neg_rate: workspace_neg_rate
        )

        stats = {
          subject_type: row.subject_type,
          subject_id: row.subject_id,
          dimension_type: row.dimension_type,
          dimension_id: row.dimension_id,
          metric_id: row.metric_id,
          window_total: window_total,
          baseline_total: baseline_total,
          eligible: true,
          workspace_window_total: workspace_window_total,
          current_rate: current_rate,
          compare_rate: compare_rate,
          delta_rate: delta_rate,
          z_score: z_score,
          z_gate_passed: z_gate_passed,
          min_window_required: min_window,
          min_baseline_required: min_baseline,
          effective_window_days: effective_window_days_for(row),
          effective_baseline_days: effective_baseline_days_for(row),
          tiny_window_floor: tiny_window_floor,
          tiny_baseline_floor: tiny_baseline_floor,
          tiny_sample: tiny_sample,
          volume_ok: volume_ok,
          min_odds_ratio: min_odds_ratio,
          min_log_odds_ratio: min_log_odds_ratio,
          min_effect_z: min_effect_z,
          max_effect_p: max_effect_p,
          qualifies: qualifies,
          reject_reasons: reject_reasons,
          score: 0.0
        }.merge(effect_stats)

        gate_reasons = effect_gate_reasons(stats)
        stats[:effect_gate_passed] = gate_reasons.empty?
        stats[:effect_gate_reasons] = gate_reasons if gate_reasons.any?
        stats.merge!(confidence_stats(stats))

        stats[:score] = score_for(stats: stats) if stats[:eligible]
        stats
      end
    end
  end
end
