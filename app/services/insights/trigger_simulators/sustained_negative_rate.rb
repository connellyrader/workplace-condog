module Insights
  module TriggerSimulators
    class SustainedNegativeRate < Base
      def run!
        window_range, baseline_range = window_and_baseline_ranges
        fired, total_seen, eligible_count, rejects = evaluate_rows(window_range: window_range, baseline_range: baseline_range)

        result(
          params: params_with_ranges(window_range: window_range, baseline_range: baseline_range),
          fired: fired,
          total_seen: total_seen,
          eligible_count: eligible_count,
          rejects: rejects
        )
      end

      private

      def build_stats(row)
        window_total = row.window_total.to_i
        baseline_total = row.baseline_total.to_i

        min_window = dynamic_min_window_for(row, baseline_total: baseline_total)
        min_baseline = dynamic_min_baseline_for(row)

        tiny_sample = tiny_sample?(window_total, baseline_total)
        volume_ok = window_total >= min_window && baseline_total >= min_baseline && !tiny_sample

        window_negative = row.window_negative.to_i
        baseline_negative = row.baseline_negative.to_i

        window_neg_rate = smoothed_rate(window_negative, window_total, negative: true)
        baseline_neg_rate = smoothed_rate(baseline_negative, baseline_total, negative: true)
        delta_neg_rate = window_neg_rate - baseline_neg_rate

        qualifies = true
        reject_reasons = []

        if min_current_rate && window_neg_rate < min_current_rate.to_f
          qualifies = false
          reject_reasons << :min_current_rate
        end

        if min_delta_rate && delta_neg_rate < min_delta_rate.to_f
          qualifies = false
          reject_reasons << :min_delta_rate
        end

        z_score = compute_z_score(
          window_rate: window_neg_rate,
          window_total: window_total,
          compare_rate: baseline_neg_rate,
          compare_total: baseline_total
        )
        z_gate_passed = min_z_score ? z_score >= min_z_score.to_f : nil

        effect_stats = compute_effect_stats(
          window_total: window_total,
          window_positive: 0,
          window_negative: window_negative,
          baseline_total: baseline_total,
          baseline_positive: 0,
          baseline_negative: baseline_negative,
          window_pos_rate: 0.0,
          window_neg_rate: window_neg_rate,
          baseline_pos_rate: 0.0,
          baseline_neg_rate: baseline_neg_rate
        )

        stats = {
          subject_type: row.subject_type,
          subject_id: row.subject_id,
          dimension_type: row.dimension_type,
          dimension_id: row.dimension_id,
          metric_id: row.metric_id,
          window_total: window_total,
          baseline_total: baseline_total,
          window_negative_count: window_negative,
          baseline_negative_count: baseline_negative,
          window_negative_rate: window_neg_rate,
          baseline_negative_rate: baseline_neg_rate,
          delta_negative_rate: delta_neg_rate,
          current_rate: window_neg_rate,
          delta_rate: delta_neg_rate,
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
          eligible: true,
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
