module Insights
  module Severity
    def self.score(template:, stats:)
      stats = stats.to_h.with_indifferent_access
      direction = template&.direction.to_s

      delta =
        case direction
        when "negative"
          stats[:delta_negative_rate] || stats[:delta_rate]
        when "positive"
          stats[:delta_positive_rate] || stats[:delta_rate]
        else
          candidates = [
            stats[:delta_negative_rate].to_f.abs,
            stats[:delta_positive_rate].to_f.abs,
            stats[:delta_rate].to_f.abs
          ]
          candidates.max
        end

      current_rate =
        case direction
        when "negative"
          stats[:window_negative_rate] || stats[:current_rate]
        when "positive"
          stats[:window_positive_rate] || stats[:current_rate]
        else
          candidates = [
            stats[:window_negative_rate].to_f,
            stats[:window_positive_rate].to_f,
            stats[:current_rate].to_f
          ]
          candidates.max
        end

      sample_factor = log1p_safe(stats[:window_total].to_i)
      weight = template&.severity_weight.to_f
      weight = 1.0 if weight <= 0

      delta.to_f * weight + current_rate.to_f * 0.5 + sample_factor * 0.2
    end

    def self.log1p_safe(value)
      if Math.respond_to?(:log1p)
        Math.log1p(value.to_f)
      else
        Math.log(1 + value.to_f)
      end
    end
  end
end
