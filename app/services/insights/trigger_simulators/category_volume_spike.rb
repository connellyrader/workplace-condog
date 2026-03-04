module Insights
  module TriggerSimulators
    class CategoryVolumeSpike < Base
      def adaptive_windows?
        false
      end

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
        totals = category_totals
        window_total = row.window_total.to_i
        baseline_total = row.baseline_total.to_i

        min_window = dynamic_min_window_for(row, baseline_total: baseline_total)
        min_baseline = dynamic_min_baseline_for(row)
        tiny_sample = tiny_sample?(window_total, baseline_total)
        volume_ok = window_total >= min_window && baseline_total >= min_baseline && !tiny_sample

        total_key = category_total_key(row)
        window_all_categories = totals[total_key][:window].to_i
        baseline_all_categories = totals[total_key][:baseline].to_i
        return nil if window_all_categories <= 0

        window_share = window_total.to_f / window_all_categories.to_f
        baseline_share = baseline_all_categories.positive? ? (baseline_total.to_f / baseline_all_categories.to_f) : 0.0
        delta_share = window_share - baseline_share

        qualifies = true
        reject_reasons = []

        if min_current_rate && window_share < min_current_rate.to_f
          qualifies = false
          reject_reasons << :min_current_rate
        end
        if min_delta_rate && delta_share < min_delta_rate.to_f
          qualifies = false
          reject_reasons << :min_delta_rate
        end

        stats = {
          subject_type: row.subject_type,
          subject_id: row.subject_id,
          dimension_type: row.dimension_type,
          dimension_id: row.dimension_id,
          metric_id: row.metric_id,
          window_total: window_total,
          baseline_total: baseline_total,
          eligible: true,
          window_total_all_categories: window_all_categories,
          baseline_total_all_categories: baseline_all_categories,
          window_share: window_share,
          baseline_share: baseline_share,
          delta_share: delta_share,
          window_positive_count: row.window_positive.to_i,
          window_negative_count: row.window_negative.to_i,
          baseline_positive_count: row.baseline_positive.to_i,
          baseline_negative_count: row.baseline_negative.to_i,
          current_rate: window_share,
          delta_rate: delta_share,
          z_score: nil,
          min_window_required: min_window,
          min_baseline_required: min_baseline,
          effective_window_days: effective_window_days_for(row),
          effective_baseline_days: effective_baseline_days_for(row),
          tiny_window_floor: tiny_window_floor,
          tiny_baseline_floor: tiny_baseline_floor,
          tiny_sample: tiny_sample,
          volume_ok: volume_ok,
          qualifies: qualifies,
          reject_reasons: reject_reasons,
          score: 0.0
        }

        gate_reasons = effect_gate_reasons(stats)
        stats[:effect_gate_passed] = gate_reasons.empty?
        stats[:effect_gate_reasons] = gate_reasons if gate_reasons.any?
        stats.merge!(confidence_stats(stats))
        stats[:score] = score_for(stats: stats) if stats[:eligible]
        stats
      end

      def category_totals
        @category_totals ||= begin
          window_range, baseline_range = window_and_baseline_ranges
          rows = aggregate_rows(window_range: window_range, baseline_range: baseline_range)

          totals = Hash.new { |h, k| h[k] = { window: 0, baseline: 0 } }
          rows.each do |row|
            key = category_total_key(row)
            totals[key][:window] += row.window_total.to_i
            totals[key][:baseline] += row.baseline_total.to_i
          end
          totals
        end
      end

      def category_total_key(row)
        [row.subject_type, row.subject_id, row.metric_id]
      end
    end
  end
end
