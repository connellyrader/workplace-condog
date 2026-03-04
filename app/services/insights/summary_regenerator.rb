module Insights
  class SummaryRegenerator
    def initialize(insights:, reference_time: Time.current, logger: Rails.logger)
      @insights = insights
      @reference_time = reference_time
      @logger = logger
    end

    def run!
      updated = []
      errors = []

      each_insight do |insight|
        candidate = build_candidate(insight)
        next unless candidate

        persister = Insights::CandidatePersister.new(
          candidates: [],
          reference_time: @reference_time,
          logger: @logger,
          generate_summary: true,
          notify: false
        )

        summary = persister.send(:generate_summary_text, insight: insight, candidate: candidate)
        insight.update!(summary_title: summary[:title], summary_body: summary[:body])
        updated << insight
      rescue => e
        @logger.error("[Insights::SummaryRegenerator] insight=#{insight.id} error #{e.class}: #{e.message}")
        errors << { insight: insight, error: e }
      end

      { updated: updated, errors: errors }
    end

    private

    def each_insight(&block)
      if @insights.respond_to?(:find_each)
        @insights.find_each(&block)
      else
        Array(@insights).each(&block)
      end
    end

    def build_candidate(insight)
      template = insight.trigger_template || InsightTriggerTemplate.find_by(id: insight.trigger_template_id)
      return nil unless template

      window_range =
        if insight.window_start_at && insight.window_end_at
          insight.window_start_at..insight.window_end_at
        end

      baseline_range =
        if insight.baseline_start_at && insight.baseline_end_at
          insight.baseline_start_at..insight.baseline_end_at
        end

      payload = insight.data_payload.is_a?(Hash) ? insight.data_payload : {}
      stats = payload["stats"] || payload[:stats] || {}

      Insights::Candidate.new(
        trigger_template: template,
        workspace: insight.workspace,
        subject_type: insight.subject_type,
        subject_id: insight.subject_id,
        dimension_type: template.dimension_type,
        dimension_id: insight.metric_id,
        window_range: window_range,
        baseline_range: baseline_range,
        stats: stats,
        severity: insight.severity || 0.0
      )
    end
  end
end
