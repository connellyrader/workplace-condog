class InsightsPipelineRunJob < ApplicationJob
  queue_as :default

  def self.cache_key(run_id)
    "insights_studio_run:#{run_id}"
  end

  def perform(run_id, baseline_mode:, logit_margin_min:, range_days: 1, mode: "dry_run", fdr_q_threshold: nil, start_date: nil)
    run = InsightPipelineRun.find_by(id: run_id)
    return unless run

    workspace = Workspace.find_by(id: run.workspace_id)
    return unless workspace

    start_date_value = parse_date(start_date)
    result =
      if start_date_value
        Insights::Studio::DailyReplayRunner.new(
          workspace: workspace,
          start_date: start_date_value,
          end_date: run.snapshot_at.to_date,
          baseline_mode: baseline_mode,
          logit_margin_min: logit_margin_min,
          fdr_q_threshold: fdr_q_threshold,
          mode: mode,
          notify: false,
          logger: Rails.logger,
          run_record: run
        ).run!
      else
        runner = Insights::Pipeline::Runner.new(
          workspace: workspace,
          snapshot_at: run.snapshot_at,
          baseline_mode: baseline_mode,
          logit_margin_min: logit_margin_min,
          range_days: range_days,
          fdr_q_threshold: fdr_q_threshold,
          mode: mode,
          notify: false,
          logger: Rails.logger,
          run_record: run
        )

        runner.run!
      end
    presenter = Insights::Studio::Presenter.new

    candidate_payloads = presenter.decorate_candidates(result.primary_candidates, snapshot_at: run.snapshot_at, run_id: run.id, include_evidence: false)
    candidate_rows = presenter.build_candidate_rows(result.primary_candidates, candidate_payloads, result.selection)

    Rails.cache.write(
      self.class.cache_key(run.id),
      {
        candidate_payloads: candidate_payloads,
        candidate_rows: candidate_rows,
        template_run_stats: result.template_stats || {}
      },
      expires_in: 30.minutes
    )
  rescue => e
    Rails.logger.error("[InsightsPipelineRunJob] run=#{run_id} failed #{e.class}: #{e.message}")
  end

  def parse_date(value)
    return nil if value.blank?
    Date.parse(value.to_s)
  rescue
    nil
  end
end
