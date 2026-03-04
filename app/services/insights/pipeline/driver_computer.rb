module Insights
  module Pipeline
    class DriverComputer
      DEFAULT_LIMIT = 3

      def initialize(workspace:, logit_margin_min:, primary_candidates:, logger: Rails.logger, limit: DEFAULT_LIMIT)
        @workspace = workspace
        @logit_margin_min = logit_margin_min.to_f
        @primary_candidates = primary_candidates
        @logger = logger
        @limit = limit.to_i
      end

      def attach!
        return if primary_candidates.blank?

        primary_candidates.each do |candidate|
          next unless candidate.window_range && candidate.baseline_range
          next if candidate.dimension_type.to_s == "summary"

          metric_id = metric_id_for(candidate)
          direction = candidate.trigger_template&.direction.to_s

          attach_submetrics(candidate, metric_id: metric_id, direction: direction)
          attach_categories(candidate, metric_id: metric_id)
        rescue => e
          logger.warn("[Insights::Pipeline::DriverComputer] failed candidate=#{candidate_key(candidate)} #{e.class}: #{e.message}")
        end
      end

      private

      attr_reader :workspace, :logit_margin_min, :primary_candidates, :logger, :limit

      def candidate_key(candidate)
        [
          candidate.trigger_template&.key,
          candidate.subject_type,
          candidate.subject_id,
          candidate.dimension_type,
          candidate.dimension_id
        ].join(":")
      end

      def metric_id_for(candidate)
        stats = candidate.stats || {}
        stats[:metric_id] || stats["metric_id"] ||
          (candidate.dimension_type == "metric" ? candidate.dimension_id : nil)
      end

      def attach_submetrics(candidate, metric_id:, direction:)
        rows = aggregate_dimension_rows(candidate, dimension_type: "submetric", metric_id: metric_id)
        return if rows.empty?

        entries = rows.filter_map do |row|
          window_total = row[:window_total]
          baseline_total = row[:baseline_total]
          next if window_total.zero? && baseline_total.zero?

          window_negative = row[:window_negative]
          baseline_negative = row[:baseline_negative]
          window_positive = row[:window_positive]
          baseline_positive = row[:baseline_positive]

          payload = {
            submetric_id: row[:dimension_id],
            window_total: window_total,
            baseline_total: baseline_total
          }

          if direction == "positive"
            window_rate = safe_rate(window_positive, window_total)
            baseline_rate = safe_rate(baseline_positive, baseline_total)
            payload[:positive_rate] = window_rate
            payload[:delta_positive_rate] = window_rate - baseline_rate
            payload[:current_rate] = window_rate
            payload[:delta_rate] = payload[:delta_positive_rate]
          else
            window_rate = safe_rate(window_negative, window_total)
            baseline_rate = safe_rate(baseline_negative, baseline_total)
            payload[:negative_rate] = window_rate
            payload[:delta_negative_rate] = window_rate - baseline_rate
            payload[:current_rate] = window_rate
            payload[:delta_rate] = payload[:delta_negative_rate]
          end

          payload
        end

        entries = entries.sort_by { |h| -h[:delta_rate].to_f }.first(limit)
        return if entries.empty?

        stats = (candidate.stats || {}).dup
        key = direction == "positive" ? :top_positive_submetrics : :top_negative_submetrics
        stats[key] = entries
        candidate.stats = stats
      end

      def attach_categories(candidate, metric_id:)
        rows = aggregate_dimension_rows(candidate, dimension_type: "category", metric_id: metric_id)
        return if rows.empty?

        window_total_all = rows.sum { |r| r[:window_total] }
        baseline_total_all = rows.sum { |r| r[:baseline_total] }

        entries = rows.filter_map do |row|
          window_total = row[:window_total]
          baseline_total = row[:baseline_total]
          next if window_total.zero? && baseline_total.zero?

          window_share = window_total_all.positive? ? (window_total.to_f / window_total_all.to_f) : 0.0
          baseline_share = baseline_total_all.positive? ? (baseline_total.to_f / baseline_total_all.to_f) : 0.0
          delta_share = window_share - baseline_share

          window_negative_rate = safe_rate(row[:window_negative], window_total)
          baseline_negative_rate = safe_rate(row[:baseline_negative], baseline_total)
          window_positive_rate = safe_rate(row[:window_positive], window_total)
          baseline_positive_rate = safe_rate(row[:baseline_positive], baseline_total)

          {
            category_id: row[:dimension_id],
            window_total: window_total,
            baseline_total: baseline_total,
            current_rate: window_share,
            delta_rate: delta_share,
            window_negative_rate: window_negative_rate,
            window_positive_rate: window_positive_rate,
            delta_negative_rate: window_negative_rate - baseline_negative_rate,
            delta_positive_rate: window_positive_rate - baseline_positive_rate
          }
        end

        entries = entries.sort_by { |h| -h[:delta_rate].to_f }.first(limit)
        return if entries.empty?

        stats = (candidate.stats || {}).dup
        stats[:top_categories] = entries
        candidate.stats = stats
      end

      def aggregate_dimension_rows(candidate, dimension_type:, metric_id:)
        window_range = candidate.window_range
        baseline_range = candidate.baseline_range
        return [] unless window_range && baseline_range

        scope = InsightDetectionRollup.where(
          workspace_id: workspace.id,
          logit_margin_min: logit_margin_min,
          subject_type: candidate.subject_type.to_s,
          subject_id: candidate.subject_id,
          dimension_type: dimension_type
        )
        scope = scope.where(metric_id: metric_id) if metric_id.present?
        scope = scope.where(posted_on: baseline_range.begin.to_date..window_range.end.to_date)

        window_start = window_range.begin.to_date
        window_end = window_range.end.to_date
        base_start = baseline_range.begin.to_date
        base_end = baseline_range.end.to_date

        rows = scope
               .group(:dimension_id)
               .select(
                 "dimension_id",
                 "SUM(CASE WHEN posted_on BETWEEN #{quote_date(window_start)} AND #{quote_date(window_end)} THEN total_count ELSE 0 END) AS window_total",
                 "SUM(CASE WHEN posted_on BETWEEN #{quote_date(window_start)} AND #{quote_date(window_end)} THEN positive_count ELSE 0 END) AS window_positive",
                 "SUM(CASE WHEN posted_on BETWEEN #{quote_date(window_start)} AND #{quote_date(window_end)} THEN negative_count ELSE 0 END) AS window_negative",
                 "SUM(CASE WHEN posted_on BETWEEN #{quote_date(base_start)} AND #{quote_date(base_end)} THEN total_count ELSE 0 END) AS baseline_total",
                 "SUM(CASE WHEN posted_on BETWEEN #{quote_date(base_start)} AND #{quote_date(base_end)} THEN positive_count ELSE 0 END) AS baseline_positive",
                 "SUM(CASE WHEN posted_on BETWEEN #{quote_date(base_start)} AND #{quote_date(base_end)} THEN negative_count ELSE 0 END) AS baseline_negative"
               )

        rows.map do |row|
          {
            dimension_id: row.dimension_id,
            window_total: row.window_total.to_i,
            window_positive: row.window_positive.to_i,
            window_negative: row.window_negative.to_i,
            baseline_total: row.baseline_total.to_i,
            baseline_positive: row.baseline_positive.to_i,
            baseline_negative: row.baseline_negative.to_i
          }
        end
      end

      def safe_rate(count, total)
        return 0.0 if total.to_i <= 0
        count.to_f / total.to_f
      end

      def quote_date(date)
        ActiveRecord::Base.connection.quote(date)
      end
    end
  end
end
