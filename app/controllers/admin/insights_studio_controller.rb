class Admin::InsightsStudioController < ApplicationController
  layout "admin"
  DEFAULT_RANGE_DAYS = 14

  before_action :authenticate_admin
  before_action :load_context

  def index
    @run = nil
    @candidate_payloads = []
    @candidate_rows = []
    @selection = nil
    load_cached_run_results if params[:run_id].present?
  end

  def run
    workspace = Workspace.find_by(id: run_params[:workspace_id])
    unless workspace
      flash.now[:alert] = "Workspace is required."
      return render :index, status: :unprocessable_entity
    end

    unless Insights::FeatureFlags.v2_enabled?
      flash.now[:alert] = "INSIGHTS_V2_ENABLED is false. Enable the flag to run V2."
      return render :index, status: :unprocessable_entity
    end

    snapshot_at = parse_time(run_params[:snapshot_at]) || Time.current
    start_date = parse_date(run_params[:start_date])
    if start_date && snapshot_at.to_date < start_date
      flash.now[:alert] = "Start date must be on or before the snapshot date."
      return render :index, status: :unprocessable_entity
    end
    baseline_mode = run_params[:baseline_mode].presence || "trailing"
    logit_margin_min = run_params[:logit_margin_min].presence || ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")
    fdr_q_threshold = run_params[:fdr_q_threshold].presence
    mode = run_params[:mode].presence || "dry_run"

    range_days = range_days_from(start_date: start_date, snapshot_at: snapshot_at)
    result =
      if start_date
        Insights::Studio::DailyReplayRunner.new(
          workspace: workspace,
          start_date: start_date,
          end_date: snapshot_at.to_date,
          baseline_mode: baseline_mode,
          logit_margin_min: logit_margin_min,
          fdr_q_threshold: fdr_q_threshold,
          mode: mode,
          notify: false,
          logger: Rails.logger
        ).run!
      else
        Insights::Pipeline::Runner.new(
          workspace: workspace,
          snapshot_at: snapshot_at,
          baseline_mode: baseline_mode,
          logit_margin_min: logit_margin_min,
          fdr_q_threshold: fdr_q_threshold,
          range_days: range_days,
          mode: mode,
          notify: false,
          logger: Rails.logger
        ).run!
      end

    @run = result.run
    @selection = result.selection
    presenter = Insights::Studio::Presenter.new
    @candidate_payloads = presenter.decorate_candidates(result.primary_candidates, snapshot_at: snapshot_at, run_id: @run&.id, include_evidence: false)
    @candidate_rows = presenter.build_candidate_rows(result.primary_candidates, @candidate_payloads, result.selection)
    apply_preview_summaries!(run: @run, payloads: @candidate_payloads, rows: @candidate_rows)
    @template_run_stats = result.template_stats || {}
    @selected_workspace = workspace
    @last_run = @run
    @status_snapshot = @run.snapshot_at
    @rollup_status = rollup_status_for(@selected_workspace, logit_margin_min: logit_margin_min.to_f)
    @rollup_range = rollup_range_for(@selected_workspace, snapshot_at: @status_snapshot, baseline_mode: baseline_mode, range_days: range_days)
    hydrate_quality_context(run: @run)

    render :index
  rescue => e
    Rails.logger.error("[InsightsStudio] run failed: #{e.class} #{e.message}")
    flash.now[:alert] = "Pipeline run failed: #{e.message}"
    render :index, status: :unprocessable_entity
  end

  def run_async
    workspace = Workspace.find_by(id: run_params[:workspace_id])
    return render json: { error: "Workspace is required." }, status: :unprocessable_entity unless workspace

    unless Insights::FeatureFlags.v2_enabled?
      return render json: { error: "INSIGHTS_V2_ENABLED is false." }, status: :unprocessable_entity
    end

    snapshot_at = parse_time(run_params[:snapshot_at]) || Time.current
    start_date = parse_date(run_params[:start_date])
    if start_date && snapshot_at.to_date < start_date
      return render json: { error: "Start date must be on or before the snapshot date." }, status: :unprocessable_entity
    end
    baseline_mode = run_params[:baseline_mode].presence || "trailing"
    logit_margin_min = run_params[:logit_margin_min].presence || ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")
    fdr_q_threshold = run_params[:fdr_q_threshold].presence
    mode = run_params[:mode].presence || "dry_run"
    range_days = range_days_from(start_date: start_date, snapshot_at: snapshot_at)

    run_record = InsightPipelineRun.create!(
      workspace: workspace,
      snapshot_at: snapshot_at,
      mode: mode,
      status: "running",
      logit_margin_min: logit_margin_min,
      timings: {
        stage: "queued",
        progress: 0.0,
        baseline_mode: baseline_mode,
        range_days: range_days,
        fdr_q_threshold: fdr_q_threshold,
        start_date: start_date&.to_s
      },
      error_payload: {}
    )

    InsightsPipelineRunJob.perform_later(
      run_record.id,
      baseline_mode: baseline_mode,
      logit_margin_min: logit_margin_min.to_f,
      range_days: range_days,
      fdr_q_threshold: fdr_q_threshold,
      mode: mode,
      start_date: start_date&.to_s
    )

    render json: { run_id: run_record.id }
  rescue => e
    Rails.logger.error("[InsightsStudio] async run failed: #{e.class} #{e.message}")
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def rollups
    workspace = Workspace.find_by(id: run_params[:workspace_id])
    unless workspace
      flash.now[:alert] = "Workspace is required."
      return render :index, status: :unprocessable_entity
    end

    snapshot_at = parse_time(run_params[:snapshot_at]) || Time.current
    start_date = parse_date(run_params[:start_date])
    if start_date && snapshot_at.to_date < start_date
      flash.now[:alert] = "Start date must be on or before the snapshot date."
      return render :index, status: :unprocessable_entity
    end
    baseline_mode = run_params[:baseline_mode].presence || "trailing"
    logit_margin_min = run_params[:logit_margin_min].presence || ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")
    range_days = range_days_from(start_date: start_date, snapshot_at: snapshot_at)

    @rollup_build_result = Insights::Pipeline::Rollups.ensure_rollups!(
      workspace: workspace,
      snapshot_at: snapshot_at,
      baseline_mode: baseline_mode,
      logit_margin_min: logit_margin_min,
      range_days: range_days,
      logger: Rails.logger
    )

    @selected_workspace = workspace
    @status_snapshot = snapshot_at
    @rollup_status = rollup_status_for(@selected_workspace, logit_margin_min: logit_margin_min.to_f)
    @rollup_range = rollup_range_for(@selected_workspace, snapshot_at: @status_snapshot, baseline_mode: baseline_mode, range_days: range_days)
    hydrate_quality_context(run: nil)

    flash.now[:notice] = "Rollups refreshed for #{workspace.name}."
    render :index
  rescue => e
    Rails.logger.error("[InsightsStudio] rollup refresh failed: #{e.class} #{e.message}")
    flash.now[:alert] = "Rollup refresh failed: #{e.message}"
    render :index, status: :unprocessable_entity
  end

  def show
    run = InsightPipelineRun.find_by(id: params[:id])
    return render json: { error: "Run not found" }, status: :not_found unless run

    render json: {
      id: run.id,
      workspace_id: run.workspace_id,
      snapshot_at: run.snapshot_at,
      mode: run.mode,
      status: run.status,
      cache_ready: Rails.cache.exist?(InsightsPipelineRunJob.cache_key(run.id)),
      logit_margin_min: run.logit_margin_min,
      candidates_total: run.candidates_total,
      candidates_primary: run.candidates_primary,
      accepted_primary: run.accepted_primary,
      persisted: run.persisted_count,
      delivered: run.delivered,
      timings: run.timings,
      errors: run.error_payload,
      created_at: run.created_at,
      updated_at: run.updated_at
    }
  end

  def preview
    candidate_data = preview_params[:candidate] || {}
    candidate_data = normalize_candidate_payload(candidate_data)

    cached_summary = summary_from_payload(candidate_data) || summary_from_cache(candidate_data)
    if cached_summary
      return render json: cached_summary
    end

    candidate, template, workspace = build_candidate_from_payload(candidate_data)

    return render json: { error: "Template not found" }, status: :unprocessable_entity unless template
    return render json: { error: "Workspace not found" }, status: :unprocessable_entity unless workspace
    return render json: { error: "Candidate not found" }, status: :unprocessable_entity unless candidate

    persister = Insights::CandidatePersister.new(candidates: [], notify: false, generate_summary: true)
    insight_stub = Insight.new(
      workspace: workspace,
      subject_type: candidate.subject_type,
      subject_id: candidate.subject_id,
      metric_id: persister.send(:metric_id_for, candidate),
      trigger_template: template,
      kind: persister.send(:insight_kind_from_template, template),
      polarity: persister.send(:polarity_from_template, template),
      severity: candidate.severity,
      window_start_at: candidate.window_range&.begin,
      window_end_at: candidate.window_range&.end,
      baseline_start_at: candidate.baseline_range&.begin,
      baseline_end_at: candidate.baseline_range&.end,
      data_payload: { stats: candidate.stats }
    )

    summary = persister.send(:generate_summary_text, insight: insight_stub, candidate: candidate, fallback: false)
    store_candidate_summary!(candidate_data, summary)
    render json: summary
  rescue => e
    Rails.logger.error("[InsightsStudio] preview failed: #{e.class} #{e.message}")
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def evidence
    candidate_data = preview_params[:candidate] || {}
    candidate_data = normalize_candidate_payload(candidate_data)
    per_page = params[:per_page].to_i if params[:per_page].present?
    page = params[:page].to_i if params[:page].present?
    per_page = 10 if per_page.nil? || per_page <= 0
    page = 1 if page.nil? || page <= 0
    offset = (page - 1) * per_page

    candidate, template, workspace = build_candidate_from_payload(candidate_data)

    return render json: { error: "Template not found" }, status: :unprocessable_entity unless template
    return render json: { error: "Workspace not found" }, status: :unprocessable_entity unless workspace
    return render json: { error: "Candidate not found" }, status: :unprocessable_entity unless candidate

    presenter = Insights::Studio::Presenter.new
    evidence = presenter.evidence_messages(candidate, limit: per_page, offset: offset)
    total_count = candidate_data[:evidence_count] || candidate_data["evidence_count"] || presenter.evidence_count(candidate)
    render json: { evidence: evidence, page: page, per_page: per_page, total_count: total_count.to_i }
  rescue => e
    Rails.logger.error("[InsightsStudio] evidence failed: #{e.class} #{e.message}")
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def persist
    render json: { error: "Persist is disabled in Insights Studio." }, status: :unprocessable_entity
  end

  private

  def run_params
    permitted = params.permit(
      :workspace_id,
      :snapshot_at,
      :start_date,
      :baseline_mode,
      :logit_margin_min,
      :fdr_q_threshold,
      :mode,
      insights_studio: [
        :workspace_id,
        :snapshot_at,
        :start_date,
        :baseline_mode,
        :logit_margin_min,
        :fdr_q_threshold,
        :mode
      ]
    )

    scoped = permitted[:insights_studio]
    scoped = scoped.to_unsafe_h if scoped.respond_to?(:to_unsafe_h)
    scoped = scoped.is_a?(Hash) ? scoped : {}
    permitted.except(:insights_studio).merge(scoped)
  end

  def preview_params
    params.permit(candidate: {})
  end

  def load_context
    @workspaces = Workspace.order(:name)
    @templates = InsightTriggerTemplate.enabled.where(primary: true).order(:key)
    @template_groups = group_templates(@templates)
    @template_run_stats = {}
    @selected_workspace = Workspace.find_by(id: params[:workspace_id])
    @selected_workspace ||= @workspaces.first if params[:workspace_id].blank? && @workspaces.one?
    snapshot_default = params[:snapshot_at].presence || latest_message_day_for(@selected_workspace) || Time.current.to_date.to_s
    snapshot_date = parse_date(snapshot_default)
    start_default = parse_date(params[:start_date]) || (snapshot_date ? snapshot_date - (DEFAULT_RANGE_DAYS - 1).days : nil)
    @defaults = {
      logit_margin_min: params[:logit_margin_min].presence || ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0"),
      baseline_mode: params[:baseline_mode].presence || "trailing",
      snapshot_at: snapshot_default,
      start_date: start_default&.to_s,
      fdr_q_threshold: params[:fdr_q_threshold].presence || ENV.fetch("INSIGHTS_FDR_Q_THRESHOLD", "0.1")
    }
    @last_run = latest_run_for(@selected_workspace)
    @status_snapshot = parse_time(@defaults[:snapshot_at]) || @last_run&.snapshot_at || Time.current
    @rollup_status = rollup_status_for(@selected_workspace, logit_margin_min: @defaults[:logit_margin_min].to_f)
    @rollup_range = rollup_range_for(
      @selected_workspace,
      snapshot_at: @status_snapshot,
      baseline_mode: @defaults[:baseline_mode],
      range_days: range_days_from(start_date: start_default, snapshot_at: @status_snapshot)
    )
    hydrate_quality_context(run: nil)
  end

  def group_templates(templates)
    templates.group_by { |t| template_family(t) }.sort.to_h
  end

  def template_family(template)
    meta = template.metadata || {}
    return meta["family"].to_s if meta["family"].present?

    case template.driver_type.to_s
    when "metric_negative_rate_spike", "metric_positive_rate_spike"
      "trend_shift"
    when "group_outlier_vs_org", "group_bright_spot_vs_org"
      "hotspot"
    when "category_volume_spike"
      "topic_shift"
    when "metric_sustained_negative_rate"
      "chronic"
    when "exec_summary"
      "exec"
    else
      "supporting"
    end
  end

  def decorate_candidates(candidates, snapshot_at: nil, run_id: nil)
    presenter = Insights::Studio::Presenter.new
    presenter.decorate_candidates(candidates, snapshot_at: snapshot_at, run_id: run_id, include_evidence: false)
  end

  def build_candidate_rows(candidates, payloads, selection)
    presenter = Insights::Studio::Presenter.new
    presenter.build_candidate_rows(candidates, payloads, selection)
  end

  def latest_run_for(workspace)
    scope = InsightPipelineRun.order(created_at: :desc)
    scope = scope.where(workspace_id: workspace.id) if workspace
    scope.first
  end

  def parse_time(value)
    return nil if value.blank?
    Time.zone.parse(value.to_s)
  rescue
    nil
  end

  def parse_date(value)
    return nil if value.blank?
    Date.parse(value.to_s)
  rescue
    nil
  end

  def range_days_from(start_date:, snapshot_at:)
    return DEFAULT_RANGE_DAYS if start_date.blank? || snapshot_at.blank?
    days = (snapshot_at.to_date - start_date.to_date).to_i + 1
    days.positive? ? days : DEFAULT_RANGE_DAYS
  end

  def parse_range(payload)
    return nil if payload.blank?
    data = payload.is_a?(String) ? (JSON.parse(payload) rescue nil) : payload
    return nil unless data.is_a?(Hash)

    start_at = parse_time(data[:start_at] || data["start_at"])
    end_at = parse_time(data[:end_at] || data["end_at"])
    return nil unless start_at && end_at

    start_at..end_at
  end

  def normalize_candidate_payload(payload)
    data = payload
    data = data.to_unsafe_h if data.respond_to?(:to_unsafe_h)
    data = data.is_a?(Hash) ? data : {}
    stats = data[:stats] || data["stats"]
    if stats.respond_to?(:to_unsafe_h)
      stats_hash = stats.to_unsafe_h
      data = data.dup
      data[:stats] = stats_hash
      data["stats"] = stats_hash
    end
    data
  end

  def summary_from_payload(payload)
    return nil unless payload.is_a?(Hash)

    summary = payload[:summary] || payload["summary"]
    title = payload[:summary_title] || payload["summary_title"]
    body = payload[:summary_body] || payload["summary_body"]

    if summary.is_a?(Hash)
      title ||= summary[:title] || summary["title"]
      body ||= summary[:body] || summary["body"]
    end

    stats = payload[:stats] || payload["stats"] || {}
    if stats.respond_to?(:to_unsafe_h)
      stats = stats.to_unsafe_h
    end

    title ||= stats[:summary_title] || stats["summary_title"]
    body ||= stats[:summary_body] || stats["summary_body"]

    return nil if title.blank? && body.blank?

    { title: title, body: body }
  end

  def summary_from_cache(payload)
    run_summary = summary_from_run(payload)
    return run_summary if run_summary

    run_id = run_id_from_payload(payload)
    if run_id.present?
      cached = Rails.cache.read(InsightsPipelineRunJob.cache_key(run_id))
      if cached.is_a?(Hash)
        payloads = cached[:candidate_payloads] || cached["candidate_payloads"]
        if payloads.is_a?(Array)
          target_key = candidate_payload_key(payload)
          matched = payloads.find { |row| candidate_payload_key(row) == target_key }
          summary = summary_from_payload(matched)
          return summary if summary
        end
      end
    end

    cached_summary = Rails.cache.read(summary_cache_key(payload))
    if cached_summary.is_a?(Hash)
      summary_from_payload(cached_summary) || cached_summary
    end
  end

  def store_candidate_summary!(payload, summary)
    run_id = run_id_from_payload(payload)
    if run_id.present?
      store_summary_in_run!(run_id: run_id, payload: payload, summary: summary)

      cache_key = InsightsPipelineRunJob.cache_key(run_id)
      cached = Rails.cache.read(cache_key)
      if cached.is_a?(Hash)
        target_key = candidate_payload_key(payload)
        payloads = cached[:candidate_payloads] || cached["candidate_payloads"]
        rows = cached[:candidate_rows] || cached["candidate_rows"]
        updated = false

        if payloads.is_a?(Array)
          payloads.each do |entry|
            next unless candidate_payload_key(entry) == target_key
            apply_summary_to_payload!(entry, summary)
            updated = true
          end
        end

        if rows.is_a?(Array)
          rows.each do |row|
            row_payload = row[:payload] || row["payload"]
            next unless row_payload
            next unless candidate_payload_key(row_payload) == target_key
            apply_summary_to_payload!(row_payload, summary)
            updated = true
          end
        end

        if updated
          cached[:candidate_payloads] = payloads if cached.key?(:candidate_payloads)
          cached["candidate_payloads"] = payloads if cached.key?("candidate_payloads")
          cached[:candidate_rows] = rows if cached.key?(:candidate_rows)
          cached["candidate_rows"] = rows if cached.key?("candidate_rows")
          Rails.cache.write(cache_key, cached, expires_in: 30.minutes)
        end
      end
    end

    summary_payload = { title: summary[:title] || summary["title"], body: summary[:body] || summary["body"] }
    Rails.cache.write(summary_cache_key(payload), summary_payload, expires_in: 30.minutes)
  end

  def apply_summary_to_payload!(payload, summary)
    return unless payload.is_a?(Hash)

    title = summary[:title] || summary["title"]
    body = summary[:body] || summary["body"]

    payload[:summary_title] = title
    payload[:summary_body] = body
    payload["summary_title"] = title
    payload["summary_body"] = body

    stats = payload[:stats] || payload["stats"]
    return unless stats.is_a?(Hash)

    stats[:summary_title] = title
    stats[:summary_body] = body
    stats["summary_title"] = title
    stats["summary_body"] = body
  end

  def apply_preview_summaries!(run:, payloads:, rows:)
    return unless run && payloads.is_a?(Array)

    timings = run.timings || {}
    preview_map = timings["preview_summaries"] || timings[:preview_summaries]
    return unless preview_map.is_a?(Hash)

    payloads.each do |payload|
      summary = preview_map[candidate_payload_key(payload)] || preview_map[candidate_payload_key(payload).to_s]
      next unless summary
      apply_summary_to_payload!(payload, summary)
    end

    Array(rows).each do |row|
      row_payload = row[:payload] || row["payload"]
      next unless row_payload
      summary = preview_map[candidate_payload_key(row_payload)] || preview_map[candidate_payload_key(row_payload).to_s]
      next unless summary
      apply_summary_to_payload!(row_payload, summary)
    end
  end

  def candidate_payload_key(payload)
    return "" unless payload.is_a?(Hash)
    [
      payload[:trigger_template_id] || payload["trigger_template_id"],
      payload[:subject_type] || payload["subject_type"],
      payload[:subject_id] || payload["subject_id"],
      payload[:dimension_type] || payload["dimension_type"],
      payload[:dimension_id] || payload["dimension_id"],
      payload_window_end_key(payload)
    ].join(":")
  end

  def payload_window_end_key(payload)
    range = payload[:window_range] || payload["window_range"]
    if range.is_a?(String)
      range = JSON.parse(range) rescue nil
    end
    end_at = range && (range[:end_at] || range["end_at"])
    return "" if end_at.blank?

    parsed = parse_time(end_at)
    parsed ? parsed.to_date.to_s : end_at.to_s
  end

  def run_id_from_payload(payload)
    payload[:run_id] || payload["run_id"]
  end

  def summary_cache_key(payload)
    "insights_studio_candidate_summary:#{run_id_from_payload(payload) || 'na'}:#{candidate_payload_key(payload)}"
  end

  def summary_from_run(payload)
    run_id = run_id_from_payload(payload)
    return nil if run_id.blank?

    run = InsightPipelineRun.find_by(id: run_id)
    return nil unless run

    timings = run.timings || {}
    preview_map = timings["preview_summaries"] || timings[:preview_summaries] || {}
    summary = preview_map[candidate_payload_key(payload)]
    summary ||= preview_map[candidate_payload_key(payload).to_s]
    summary_from_payload(summary)
  end

  def store_summary_in_run!(run_id:, payload:, summary:)
    run = InsightPipelineRun.find_by(id: run_id)
    return unless run

    timings = run.timings || {}
    preview_map = timings["preview_summaries"] || timings[:preview_summaries] || {}
    preview_map = preview_map.is_a?(Hash) ? preview_map.dup : {}
    preview_map[candidate_payload_key(payload)] = {
      title: summary[:title] || summary["title"],
      body: summary[:body] || summary["body"]
    }

    timings = timings.deep_dup rescue timings.dup
    timings["preview_summaries"] = preview_map
    timings[:preview_summaries] = preview_map
    run.update!(timings: timings)
  rescue => e
    Rails.logger.warn("[InsightsStudio] failed to store preview summary run=#{run_id} #{e.class}: #{e.message}")
  end

  def build_candidate_from_payload(candidate_data)
    template = InsightTriggerTemplate.find_by(id: candidate_data[:trigger_template_id] || candidate_data["trigger_template_id"])
    workspace = Workspace.find_by(id: candidate_data[:workspace_id] || candidate_data["workspace_id"])
    return [nil, template, workspace] unless template && workspace

    candidate = Insights::Candidate.new(
      trigger_template: template,
      workspace: workspace,
      subject_type: candidate_data[:subject_type] || candidate_data["subject_type"],
      subject_id: candidate_data[:subject_id] || candidate_data["subject_id"],
      dimension_type: candidate_data[:dimension_type] || candidate_data["dimension_type"],
      dimension_id: candidate_data[:dimension_id] || candidate_data["dimension_id"],
      window_range: parse_range(candidate_data[:window_range] || candidate_data["window_range"]),
      baseline_range: parse_range(candidate_data[:baseline_range] || candidate_data["baseline_range"]),
      stats: candidate_data[:stats] || candidate_data["stats"] || {},
      severity: (candidate_data[:severity] || candidate_data["severity"]).to_f
    )

    [candidate, template, workspace]
  end

  def rollup_status_for(workspace, logit_margin_min:)
    return { row_count: 0, total_detections: 0, date_range: nil, last_updated: nil } unless workspace

    scope = InsightDetectionRollup.where(workspace_id: workspace.id, logit_margin_min: logit_margin_min.to_f)
    row_count = scope.count
    return { row_count: 0, total_detections: 0, date_range: nil, last_updated: nil } if row_count.zero?

    {
      row_count: row_count,
      total_detections: scope.sum(:total_count),
      date_range: [scope.minimum(:posted_on), scope.maximum(:posted_on)].compact.map(&:to_s).join(" → "),
      last_updated: scope.maximum(:updated_at)&.iso8601
    }
  end

  def rollup_range_for(workspace, snapshot_at:, baseline_mode:, range_days: DEFAULT_RANGE_DAYS)
    return nil unless workspace && snapshot_at

    start_date, end_date = Insights::Pipeline::Rollups.rollup_range_for(
      workspace: workspace,
      snapshot_at: snapshot_at,
      baseline_mode: baseline_mode,
      range_days: range_days
    )

    { start_date: start_date, end_date: end_date }
  end

  def hydrate_quality_context(run:)
    @recommendations = build_recommendations(
      workspace: @selected_workspace,
      run: run || @last_run,
      rollup_status: @rollup_status
    )
  end

  def build_recommendations(workspace:, run:, rollup_status:)
    recs = []
    unless workspace
      recs << "Select a workspace to run insights."
      return recs
    end

    timings = run&.timings || {}
    quality = timings["quality"] || timings[:quality] || {}
    filter_counts = quality["filter_counts"] || quality[:filter_counts] || {}
    completeness = timings["completeness"] || timings[:completeness] || {}

    if rollup_status[:row_count].to_i.zero?
      recs << "No rollups yet — refresh rollups to populate candidates."
    end

    if run
      if run.candidates_primary.to_i.zero?
        recs << "No candidates fired — consider lowering logit margin threshold or widening the window."
      elsif run.accepted_primary.to_i.zero?
        recs << "All candidates filtered — review cooldowns or max-per-window limits."
      end
    else
      recs << "Run a dry-run to generate candidates and preview narratives."
    end

    min_volume_filtered = filter_counts["min_volume"].to_i + filter_counts["min_baseline"].to_i
    if min_volume_filtered.positive?
      recs << "Many candidates filtered by min-volume — consider lowering minimum detections or increasing window caps."
    end

    if filter_counts["fdr"].to_i.positive?
      recs << "FDR filtered some candidates — adjust q threshold if the run feels too strict."
    end

    if completeness["status"].to_s == "shifted"
      recs << "Snapshot shifted due to low completeness — data may be partial for the latest day."
    elsif completeness["status"].to_s == "unknown"
      recs << "Completeness could not be assessed — ensure rollups have enough history."
    end

    recs.first(5)
  end

  def load_cached_run_results
    run_id = params[:run_id].to_s
    return if run_id.blank?

    run = InsightPipelineRun.find_by(id: run_id)
    return unless run

    cached = Rails.cache.read(InsightsPipelineRunJob.cache_key(run.id)) || {}
    @run = run
    @last_run = run
    @candidate_payloads = cached[:candidate_payloads] || cached["candidate_payloads"] || []
    @candidate_rows = cached[:candidate_rows] || cached["candidate_rows"] || []
    @template_run_stats = cached[:template_run_stats] || cached["template_run_stats"] || {}
    apply_preview_summaries!(run: @run, payloads: @candidate_payloads, rows: @candidate_rows)

    if @candidate_rows.empty? && run.status == "ok" && run.candidates_primary.to_i.positive?
      rebuild_cached_run_results(run)
    end
  end

  def rebuild_cached_run_results(run)
    baseline_mode = (run.timings["baseline_mode"] || run.timings[:baseline_mode] || @defaults[:baseline_mode] || "trailing").to_s
    range_days = (run.timings["range_days"] || run.timings[:range_days] || run_range_days).to_i
    fdr_q_threshold = run.timings["fdr_q_threshold"] || run.timings[:fdr_q_threshold]
    start_date = parse_date(run.timings["start_date"] || run.timings[:start_date])

    result =
      if start_date
        Insights::Studio::DailyReplayRunner.new(
          workspace: run.workspace,
          start_date: start_date,
          end_date: run.snapshot_at.to_date,
          baseline_mode: baseline_mode,
          logit_margin_min: run.logit_margin_min,
          fdr_q_threshold: fdr_q_threshold,
          mode: run.mode,
          notify: false,
          logger: Rails.logger,
          run_record: run
        ).run!
      else
        Insights::Pipeline::Runner.new(
          workspace: run.workspace,
          snapshot_at: run.snapshot_at,
          baseline_mode: baseline_mode,
          logit_margin_min: run.logit_margin_min,
          range_days: range_days,
          fdr_q_threshold: fdr_q_threshold,
          mode: run.mode,
          notify: false,
          logger: Rails.logger,
          run_record: run
        ).run!
      end

    presenter = Insights::Studio::Presenter.new
    @candidate_payloads = presenter.decorate_candidates(result.primary_candidates, snapshot_at: run.snapshot_at, run_id: run.id, include_evidence: false)
    @candidate_rows = presenter.build_candidate_rows(result.primary_candidates, @candidate_payloads, result.selection)
    apply_preview_summaries!(run: run, payloads: @candidate_payloads, rows: @candidate_rows)
    @template_run_stats = result.template_stats || {}

    Rails.cache.write(
      InsightsPipelineRunJob.cache_key(run.id),
      {
        candidate_payloads: @candidate_payloads,
        candidate_rows: @candidate_rows,
        template_run_stats: @template_run_stats
      },
      expires_in: 30.minutes
    )
  rescue => e
    Rails.logger.error("[InsightsStudio] fallback rebuild failed run=#{run.id} #{e.class}: #{e.message}")
  end

  def latest_message_day_for(workspace)
    return nil unless workspace

    Message.joins(:integration)
           .where(integrations: { workspace_id: workspace.id })
           .maximum(Arel.sql(Insights::QueryHelpers::POSTED_AT_SQL))
           &.to_date
           &.to_s
  rescue => e
    Rails.logger.warn("[InsightsStudio] failed to load latest message date: #{e.message}")
    nil
  end

  def run_range_days
    DEFAULT_RANGE_DAYS
  end

end

