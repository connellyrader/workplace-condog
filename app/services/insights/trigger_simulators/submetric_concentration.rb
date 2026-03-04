module Insights
  module TriggerSimulators
    class SubmetricConcentration < Base
      def adaptive_windows?
        false
      end

      def qualifying_stats
        window_range, baseline_range = window_and_baseline_ranges
        rows = aggregate_rows(window_range: window_range, baseline_range: baseline_range, dimension_types: ["submetric"])

        metric_target_totals = Hash.new { |h, k| h[k] = { window: 0, baseline: 0 } }
        rows.each do |row|
          next unless row.metric_id
          key = metric_key(row)
          metric_target_totals[key][:window] += target_count(row, :window)
          metric_target_totals[key][:baseline] += target_count(row, :baseline)
        end

        fired = []
        total_seen = 0
        eligible_count = 0
        rejects = Hash.new(0)

        rows.each do |row|
          next unless row.metric_id

          stats = build_stats(row, metric_target_totals: metric_target_totals)
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
        rows = aggregate_rows(window_range: window_range, baseline_range: baseline_range, dimension_types: ["submetric"])

        metric_target_totals = Hash.new { |h, k| h[k] = { window: 0, baseline: 0 } }
        rows.each do |row|
          next unless row.metric_id
          key = metric_key(row)
          metric_target_totals[key][:window] += target_count(row, :window)
          metric_target_totals[key][:baseline] += target_count(row, :baseline)
        end

        fired = []
        total_seen = 0
        eligible_count = 0
        rejects = Hash.new(0)

        rows.each do |row|
          next unless row.metric_id

          stats = build_stats(row, metric_target_totals: metric_target_totals)
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

      def build_stats(row, metric_target_totals:)
        window_total = row.window_total.to_i
        baseline_total = row.baseline_total.to_i
        min_window = dynamic_min_window_for(row, baseline_total: baseline_total)
        min_baseline = dynamic_min_baseline_for(row)
        tiny_sample = tiny_sample?(window_total, baseline_total)
        volume_ok = window_total >= min_window && baseline_total >= min_baseline && !tiny_sample

        key = metric_key(row)
        metric_window_target_total = metric_target_totals[key][:window].to_i
        metric_baseline_target_total = metric_target_totals[key][:baseline].to_i
        target_window = target_count(row, :window)
        target_baseline = target_count(row, :baseline)

        return nil if metric_window_target_total <= 0

        window_share = target_window.to_f / metric_window_target_total
        baseline_share = metric_baseline_target_total.positive? ? (target_baseline.to_f / metric_baseline_target_total) : 0.0
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
          window_target_count: target_window,
          baseline_target_count: target_baseline,
          metric_window_target_total: metric_window_target_total,
          metric_baseline_target_total: metric_baseline_target_total,
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

      def target_count(row, period)
        case direction.to_s
        when "positive"
          period == :window ? row.window_positive.to_i : row.baseline_positive.to_i
        else
          period == :window ? row.window_negative.to_i : row.baseline_negative.to_i
        end
      end

      def metric_key(row)
        [row.subject_type, row.subject_id, row.metric_id]
      end
    end
  end
end
