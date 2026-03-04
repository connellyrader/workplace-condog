require "set"

module Insights
  class CandidateSelector
    Result = Struct.new(:accepted, :rejected, keyword_init: true)

    def initialize(candidates:, reference_time: Time.current, virtual_insights: nil, as_of: nil)
      @candidates = candidates
      @reference_time = reference_time
      @virtual_insights = Array(virtual_insights)
      @as_of = as_of
      @accepted = []
      @rejected = []
      @per_subject_template_counts = Hash.new(0)
    end

    def select!
      prepare_insight_lookups

      group_candidates_by_subject.each do |_subject_key, subject_candidates|
        subject_candidates
          .sort_by { |c| -c.severity.to_f }
          .each do |candidate|
            allowed, reason = allowed_with_reason(candidate)
            if allowed
              @accepted << candidate
              increment_in_memory_counts(candidate)
            else
              @rejected << { candidate: candidate, reason: reason }
            end
          end
      end

      Result.new(accepted: @accepted, rejected: @rejected)
    end

    private

    def group_candidates_by_subject
      @candidates.group_by do |c|
        [c.workspace.id, c.subject_type.to_s, c.subject_id]
      end
    end

    def prepare_insight_lookups
      @recent_subject_insight_keys = Set.new
      @subject_template_insights = Hash.new { |h, k| h[k] = [] }

      return if @candidates.empty?

      subject_keys = @candidates.map { |c| subject_key(c) }
      workspace_ids = subject_keys.map(&:first).uniq
      subject_types = subject_keys.map { |(_, st, _)| st }.uniq
      subject_ids = subject_keys.map { |(_, _, sid)| sid }.uniq
      template_ids = @candidates.filter_map { |c| c.trigger_template&.id }.uniq

      preload_recent_subject_insights(workspace_ids, subject_types, subject_ids)
      preload_subject_template_insights(workspace_ids, subject_types, subject_ids, template_ids)
      merge_virtual_insights
    end

    def preload_recent_subject_insights(workspace_ids, subject_types, subject_ids)
      recent_types = subject_types & %w[User Group IntegrationUser]
      return if recent_types.empty?

      lookback_start = reference_time - 48.hours

      scope = Insight.where(workspace_id: workspace_ids, subject_type: recent_types, subject_id: subject_ids)
             .where.not(state: "suppressed")
             .where("COALESCE(delivered_at, created_at) >= ?", lookback_start)
      scope = scope.where("COALESCE(delivered_at, created_at) <= ?", as_of) if as_of
      scope
             .distinct
             .pluck(:workspace_id, :subject_type, :subject_id)
             .each { |triple| recent_subject_insight_keys << triple }
    end

    def preload_subject_template_insights(workspace_ids, subject_types, subject_ids, template_ids)
      return if template_ids.empty? || subject_types.empty?

      since_time = earliest_insight_since_time
      arel = Insight.arel_table
      condition =
        if since_time
          arel[:next_eligible_at].gt(reference_time).or(arel[:created_at].gteq(since_time))
        else
          arel[:next_eligible_at].gt(reference_time)
        end

      scope = Insight.where(workspace_id: workspace_ids, subject_type: subject_types, subject_id: subject_ids, trigger_template_id: template_ids)
                     .where.not(state: "suppressed")
                     .where(condition)
      scope = scope.where(Insight.arel_table[:created_at].lteq(as_of)) if as_of
      scope.select(:id, :workspace_id, :subject_type, :subject_id, :trigger_template_id, :created_at, :next_eligible_at)
           .find_each do |ins|
        subject_template_insights[subject_template_key_from_record(ins)] << ins
      end
    end

    def merge_virtual_insights
      return if virtual_insights.empty?

      lookback_start = reference_time - 48.hours
      virtual_insights.each do |ins|
        next unless ins
        next if as_of && ins.created_at && ins.created_at > as_of

        if %w[User Group IntegrationUser].include?(ins.subject_type.to_s)
          created_at = ins.respond_to?(:delivered_at) ? (ins.delivered_at || ins.created_at) : ins.created_at
          if created_at && created_at >= lookback_start
            recent_subject_insight_keys << [ins.workspace_id, ins.subject_type.to_s, ins.subject_id]
          end
        end

        key = subject_template_key_from_record(ins)
        subject_template_insights[key] << ins if key
      end
    end

    def earliest_insight_since_time
      days_lookback = @candidates.filter_map do |candidate|
        template = candidate.trigger_template
        next unless template

        [template.cooldown_days.to_i, template.window_days.to_i].max
      end
      return nil if days_lookback.empty?

      reference_time - days_lookback.max.days
    end

    def allowed_with_reason(candidate)
      template = candidate.trigger_template
      return [false, :missing_template] unless template
      return [true, nil] if template.key.to_s == "exec_summary"
      return [false, :cooldown] if cooldown_active?(candidate, template)
      return [false, :recent_subject_insight] if recent_subject_insight?(candidate)
      return [false, :budget] if subject_template_budget_reached?(candidate, template)

      [true, nil]
    end

    def cooldown_active?(candidate, template)
      days = template.cooldown_days.to_i
      return false if days <= 0

      since_time = reference_time - days.days

      insights_for(candidate, template).any? do |ins|
        (ins.next_eligible_at && ins.next_eligible_at > reference_time) ||
          (ins.created_at && ins.created_at >= since_time)
      end
    end

    # Reject if this subject has received any insight within the last 48 hours,
    # to avoid spamming individuals or groups regardless of template cooldowns.
    def recent_subject_insight?(candidate)
      return false unless %w[User Group IntegrationUser].include?(candidate.subject_type.to_s)

      recent_subject_insight_keys.include?(subject_key(candidate))
    end

    def subject_template_budget_reached?(candidate, template)
      max = template.max_per_subject_per_window
      return false unless max.present? && max.to_i > 0

      insights = insights_for(candidate, template)
      since_time = reference_time - template.window_days.to_i.days

      existing_count = insights.count { |ins| ins.created_at && ins.created_at >= since_time }
      in_memory_count = @per_subject_template_counts[subject_template_key(candidate, template)]

      (existing_count + in_memory_count) >= max.to_i
    end

    def subject_template_key(candidate, template)
      [candidate.workspace.id, candidate.subject_type.to_s, candidate.subject_id, template.id]
    end

    def subject_template_key_from_record(record)
      [record.workspace_id, record.subject_type.to_s, record.subject_id, record.trigger_template_id]
    end

    def subject_key(candidate)
      [candidate.workspace.id, candidate.subject_type.to_s, candidate.subject_id]
    end

    def insights_for(candidate, template)
      subject_template_insights[subject_template_key(candidate, template)]
    end

    def subject_template_insights
      @subject_template_insights ||= Hash.new { |h, k| h[k] = [] }
    end

    def recent_subject_insight_keys
      @recent_subject_insight_keys ||= Set.new
    end

    def increment_in_memory_counts(candidate)
      template = candidate.trigger_template
      return unless template

      key = subject_template_key(candidate, template)
      @per_subject_template_counts[key] += 1
    end

    attr_reader :reference_time, :virtual_insights, :as_of
  end
end
