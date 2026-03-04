module Insights
  class CandidateFdrGate
    Result = Struct.new(:accepted, :rejected, keyword_init: true)

    def initialize(candidates:, q_threshold: 0.1, min_tests: nil, min_window_total: nil, min_baseline_total: nil)
      @candidates = Array(candidates)
      @q_threshold = q_threshold.to_f
      @min_tests = (min_tests || ENV.fetch("INSIGHTS_FDR_MIN_TESTS", "50")).to_i
      @min_window_total = (min_window_total || ENV.fetch("INSIGHTS_FDR_MIN_WINDOW", "20")).to_i
      @min_baseline_total = (min_baseline_total || ENV.fetch("INSIGHTS_FDR_MIN_BASELINE", "50")).to_i
    end

    def apply!
      return Result.new(accepted: [], rejected: []) if candidates.empty?

      entries = candidates.map { |candidate| { candidate: candidate, p: p_value_for(candidate) } }
      eligible = entries.select { |entry| fdr_applicable?(entry[:candidate]) }

      if eligible.size < min_tests
        candidates.each do |candidate|
          stats = (candidate.stats || {}).with_indifferent_access
          stats[:fdr_applicable] = false
          stats[:fdr_reason] = "insufficient_tests"
          stats[:fdr_pass] = nil
          stats.delete(:q_value)
          candidate.stats = stats
        end
        return Result.new(accepted: candidates, rejected: [])
      end

      eligible.sort_by! { |entry| entry[:p] }

      total = eligible.size
      eligible.each_with_index do |entry, idx|
        rank = idx + 1
        entry[:q] = entry[:p].to_f * total.to_f / rank.to_f
      end

      min_q = 1.0
      eligible.reverse_each do |entry|
        min_q = [min_q, entry[:q]].min
        entry[:q] = min_q
      end

      accepted = []
      rejected = []

      entries.each do |entry|
        candidate = entry[:candidate]
        stats = (candidate.stats || {}).with_indifferent_access
        if fdr_applicable?(candidate)
          q_value = [entry[:q].to_f, 1.0].min
          stats[:q_value] = q_value
          stats[:fdr_applicable] = true
          stats[:fdr_pass] = q_value <= q_threshold
          stats.delete(:fdr_reason)
          candidate.stats = stats

          if q_value <= q_threshold
            accepted << candidate
          else
            rejected << { candidate: candidate, reason: :fdr }
          end
        else
          stats[:fdr_applicable] = false
          stats[:fdr_reason] = "low_volume"
          stats[:fdr_pass] = nil
          stats.delete(:q_value)
          candidate.stats = stats
          accepted << candidate
        end
      end

      Result.new(accepted: accepted, rejected: rejected)
    end

    private

    attr_reader :candidates, :q_threshold, :min_tests, :min_window_total, :min_baseline_total

    def p_value_for(candidate)
      stats = (candidate.stats || {}).with_indifferent_access
      raw = stats[:effect_p] || stats[:p_value] || stats[:p] || stats[:z_p]
      return 1.0 if raw.nil?
      value = raw.to_f
      return 1.0 unless value.finite?
      return 1.0 if value < 0.0

      [value, 1.0].min
    end

    def fdr_applicable?(candidate)
      stats = (candidate.stats || {}).with_indifferent_access
      window_total = stats[:window_total].to_i
      baseline_total = stats[:baseline_total].to_i
      return false if window_total < min_window_total
      return false if baseline_total < min_baseline_total

      true
    end
  end
end
