# app/controllers/admin/prompts_controller.rb
class Admin::PromptsController < ApplicationController
  layout "admin"

  before_action :authenticate_admin
  before_action :set_prompt_key, only: [:show, :overview_preview, :insight_preview]
  before_action :load_prompt_data, only: [:show, :overview_preview, :insight_preview]

  helper_method :template_prompt_key
  helper_method :default_insight_prompt_text
  helper_method :default_overview_prompt_text
  helper_method :default_ai_chat_prompt_text

  def index
    templates = InsightTriggerTemplate.order(:name)
    @prompt_rows = [
      { key: "clara_overview", name: "Clara Metric Overview", type: "Overview", active: PromptVersion.active_for("clara_overview") }
    ]
    templates.each do |t|
      key = template_prompt_key(t)
      @prompt_rows << { key: key, name: t.name, type: "Insight template", active: PromptVersion.active_for(key) }
    end
  end

  def show
  end

  def overview_preview
    unless @prompt_key == "clara_overview"
      redirect_to admin_prompt_path(@prompt_key), alert: "Preview only available for Clara overviews." and return
    end

    workspace = Workspace.find_by(id: params[:workspace_id])
    metric    = Metric.find_by(id: params[:metric_id])

    if workspace.nil? || metric.nil?
      return render_preview_error("Workspace and metric are required.", field: :overview_preview_error)
    end

    range_start = parse_date(params[:range_start]) || 30.days.ago.to_date
    range_end   = parse_date(params[:range_end])   || Date.current

    prompt_override = prompt_version_content(params[:prompt_version_id])
    generator = Clara::OverviewGenerator.new(
      overview: ClaraOverview.new(workspace: workspace, metric: metric),
      workspace: workspace,
      metric: metric,
      stream_key: "admin-overview-preview-#{SecureRandom.hex(4)}",
      range_start: range_start,
      range_end: range_end,
      member_ids: nil,
      prompt_override: prompt_override
    )

    @overview_preview_text, @overview_snapshot = generator.preview!(prompt_override: prompt_override)
    @overview_preview_meta = {
      workspace: workspace,
      metric: metric,
      range_start: range_start,
      range_end: range_end,
      prompt_version_id: params[:prompt_version_id]
    }
    json_meta = {
      workspace: { id: workspace.id, name: workspace.name },
      metric: { id: metric.id, name: metric.name },
      range_start: range_start,
      range_end: range_end,
      prompt_version_id: params[:prompt_version_id]
    }
    run = record_prompt_test_run!(
      prompt_type: "clara_overview",
      prompt_version_id: params[:prompt_version_id],
      title: "Overview preview",
      body: @overview_preview_text,
      metadata: {
        workspace_id: workspace.id,
        workspace_name: workspace.name,
        metric_id: metric.id,
        metric_name: metric.name,
        range_start: range_start,
        range_end: range_end,
        prompt_override_used: prompt_override.present?
      }
    )

    respond_to do |format|
      format.html { render :show }
      format.json do
        render json: {
          preview: { text: @overview_preview_text, meta: json_meta },
          run: prompt_test_run_json(run)
        }
      end
    end
  rescue => e
    render_preview_error("Preview failed: #{e.message}", field: :overview_preview_error)
  end

  def insight_preview
    unless @prompt_type == :insight_template
      redirect_to admin_prompt_path(@prompt_key), alert: "Preview only available for insight templates." and return
    end

    template = @prompt_template
    prompt_override = prompt_version_content(params[:prompt_version_id])
    preview_workspace = preview_workspace_from_params
    candidate_source = :insight
    detection_used = nil
    candidate = nil
    insight = nil

    if template.key == "exec_summary"
      workspace, candidate, candidate_source = exec_summary_candidate_for(template)
      unless candidate
        return render_preview_error("No data found to generate an executive summary.", field: :insight_preview_error)
      end
      insight = build_virtual_insight_from_candidate(candidate)
    else
      insight = find_insight_for_preview(template, workspace: preview_workspace)
      if params[:insight_id].present? && insight.nil?
        return render_preview_error("Insight ##{params[:insight_id]} not found for #{template.name}.", field: :insight_preview_error)
      end

      unless insight
        return render_preview_error("No existing insight found for #{template.name}. Run the pipeline to generate one, then preview again.", field: :insight_preview_error)
      end

      candidate = candidate_from_insight(insight)
      unless candidate
        return render_preview_error("No matching candidate found for #{template.name}.", field: :insight_preview_error)
      end
    end

    detection_used_id = detection_used&.id

    persister = Insights::CandidatePersister.new(
      candidates: [],
      reference_time: Time.current,
      logger: Rails.logger,
      generate_summary: true,
      notify: false
    )

    summary = persister.send(
      :generate_summary_text,
      insight: insight,
      candidate: candidate,
      prompt_override: prompt_override
    )

    @insight_preview = {
      summary: summary,
      insight: insight,
      template: template,
      prompt_version_id: params[:prompt_version_id],
      prompt_override_used: prompt_override.present?
    }
    run = record_prompt_test_run!(
      prompt_type: "insight_template",
      prompt_version_id: params[:prompt_version_id],
      title: summary[:title],
      body: summary[:body],
      metadata: {
      template_id: template.id,
      template_key: template.key,
      template_name: template.name,
      insight_id: insight&.id,
      detection_id: detection_used_id,
      candidate_source: candidate_source.to_s,
      prompt_override_used: prompt_override.present?,
      subject_type: candidate&.subject_type,
      subject_id: candidate&.subject_id,
      workspace_id: insight&.workspace_id,
        workspace_name: insight&.workspace&.name
      }
    )

    respond_to do |format|
      format.html { render :show }
      format.json do
        render json: {
          preview: {
            title: summary[:title],
            body: summary[:body],
            insight_id: insight&.id,
            detection_id: detection_used_id,
            prompt_version_id: params[:prompt_version_id]
          },
          run: prompt_test_run_json(run)
        }
      end
    end
  rescue => e
    render_preview_error("Preview failed: #{e.message}", field: :insight_preview_error)
  end

  private

  def set_prompt_key
    @prompt_key = params[:key].to_s
    if @prompt_key.blank?
      redirect_to admin_prompts_path, alert: "Prompt key required." and return
    end
  end

  def load_prompt_data
    if @prompt_key == "ai_chat"
      redirect_to admin_prompts_path, alert: "Use the chat widget to test AI Chat prompts." and return
    end

    @workspaces = Workspace.order(:name)
    @metrics    = Metric.order(:name)
    @templates  = InsightTriggerTemplate.order(:name)
    @latest_insights_by_template = Insight
                                    .includes(:trigger_template, :workspace)
                                    .where(trigger_template_id: @templates.map(&:id))
                                    .order(created_at: :desc)
                                    .limit(50)
                                    .group_by(&:trigger_template_id)

    case @prompt_key
    when "ai_chat"
      @prompt_name        = "AI Chat"
      @prompt_type        = :ai_chat
      @versions           = PromptVersion.for_key("ai_chat")
      @active_version     = PromptVersion.active_for("ai_chat")
      @default_prompt_body = default_ai_chat_prompt_text
    when "clara_overview"
      @prompt_name        = "Clara Metric Overview"
      @prompt_type        = :clara_overview
      @versions           = PromptVersion.for_key("clara_overview")
      @active_version     = PromptVersion.active_for("clara_overview")
      @default_prompt_body = default_overview_prompt_text
      @prefill_prompt     = @active_version&.content.presence || @default_prompt_body
    else
      @prompt_template    = @templates.find { |t| template_prompt_key(t) == @prompt_key }
      unless @prompt_template
        redirect_to admin_prompts_path, alert: "Prompt not found." and return
      end
      @prompt_name        = @prompt_template.name
      @prompt_type        = :insight_template
      @versions           = PromptVersion.for_key(@prompt_key)
      @active_version     = PromptVersion.active_for(@prompt_key)
      @default_prompt_body = default_insight_prompt_text
      base_body           = @active_version&.content.presence || @default_prompt_body
      merged              = [base_body, @prompt_template.system_prompt.presence].compact.join("\n\n").presence
      @prefill_prompt     = merged || base_body
    end
  end

  def parse_date(val)
    return nil if val.blank?
    Date.parse(val.to_s)
  rescue ArgumentError
    nil
  end

  def render_preview_error(message, field:)
    instance_variable_set("@#{field}", message) if field
    respond_to do |format|
      format.html { render :show }
      format.json { render json: { error: message }, status: :unprocessable_entity }
    end
  end

  def record_prompt_test_run!(prompt_type:, prompt_version_id:, title:, body:, metadata: {})
    PromptTestRun.create!(
      prompt_key: @prompt_key,
      prompt_type: prompt_type.to_s,
      prompt_version_id: prompt_version_id.presence,
      title: title,
      body: body,
      metadata: metadata || {},
      created_by: current_user
    )
  rescue => e
    Rails.logger.warn("[Admin::PromptsController] prompt test run record failed: #{e.message}")
    nil
  end

  def prompt_test_run_json(run)
    run&.as_json_for_api
  end

  def prompt_version_content(id)
    return nil unless id.present?
    PromptVersion.find_by(id: id)&.content
  end

  def find_template_from_params
    if params[:template_id].present?
      InsightTriggerTemplate.find_by(id: params[:template_id])
    elsif params[:template_key].present?
      InsightTriggerTemplate.find_by(key: params[:template_key])
    else
      nil
    end
  end

  def find_insight_for_preview(template, workspace: nil)
    if params[:insight_id].present?
      scope = Insight.where(id: params[:insight_id], trigger_template_id: template.id)
      scope = scope.where(workspace_id: workspace.id) if workspace
      scope.first
    else
      insights =
        if workspace
          Insight.where(trigger_template_id: template.id, workspace_id: workspace.id).order(created_at: :desc).limit(5)
        else
          Array(@latest_insights_by_template[template.id])
        end
      insights.first
    end
  end

  def candidate_from_insight(insight)
    template = insight.trigger_template
    payload  = insight.data_payload || {}

    window_range   = if insight.window_start_at && insight.window_end_at
                       insight.window_start_at..insight.window_end_at
                     end
    baseline_range = if insight.baseline_start_at && insight.baseline_end_at
                       insight.baseline_start_at..insight.baseline_end_at
                     end

    dimension_type = payload["dimension_type"] || template&.dimension_type || "metric"
    dimension_id   = payload["dimension_id"]   || insight.metric_id

    Insights::Candidate.new(
      trigger_template: template,
      workspace: insight.workspace,
      subject_type: insight.subject_type,
      subject_id: insight.subject_id,
      dimension_type: dimension_type,
      dimension_id: dimension_id,
      window_range: window_range,
      baseline_range: baseline_range,
      stats: payload["stats"] || payload[:stats],
      severity: insight.severity
    )
  end

  def exec_summary_candidate_for(template)
    workspace = exec_summary_workspace_from_params || workspace_with_recent_detections || @workspaces.first
    return [nil, nil, :exec_summary] unless workspace

    runner = Insights::ExecSummaryRunner.new(
      workspaces: [workspace],
      reference_time: Time.current,
      logit_margin_threshold: ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f
    )

    primary = build_exec_summary_candidate(runner: runner, workspace: workspace, template: template)
    return [workspace, primary, :exec_summary] if primary

    fallback = build_exec_summary_fallback_candidate(runner: runner, workspace: workspace, template: template)
    [workspace, fallback, fallback ? :exec_summary_fallback : :exec_summary]
  rescue => e
    Rails.logger.warn("[Admin::PromptsController] exec summary candidate failed: #{e.message}")
    [workspace, nil, :exec_summary]
  end

  def exec_summary_workspace_from_params
    return nil unless params[:workspace_id].present?

    Workspace.find_by(id: params[:workspace_id])
  end

  def preview_workspace_from_params
    return @preview_workspace if defined?(@preview_workspace)

    @preview_workspace =
      if params[:workspace_id].present?
        Workspace.find_by(id: params[:workspace_id])
      else
        nil
      end
  end

  def workspace_with_recent_detections
    det = Detection.joins(message: :integration).order(created_at: :desc).first
    det&.message&.integration&.workspace
  end

  def build_exec_summary_candidate(runner:, workspace:, template:)
    runner.send(:build_candidate, workspace: workspace, template: template)
  rescue => e
    Rails.logger.warn("[Admin::PromptsController] exec summary build candidate failed: #{e.message}")
    nil
  end

  def build_exec_summary_fallback_candidate(runner:, workspace:, template:)
    window_range, baseline_range = runner.send(:window_and_baseline_ranges, template)
    recent_insights = runner.send(:recent_insights_for, workspace, since: baseline_range.begin)

    stats = {
      window_total: 0,
      baseline_total: 0,
      window_negative_count: 0,
      window_positive_count: 0,
      baseline_negative_count: 0,
      baseline_positive_count: 0,
      window_negative_rate: 0.0,
      window_positive_rate: 0.0,
      baseline_negative_rate: 0.0,
      baseline_positive_rate: 0.0,
      metric_negative_rate_deltas: [],
      recent_insights: recent_insights
    }

    severity = runner.send(:log1p_safe, stats[:window_total])

    Insights::Candidate.new(
      trigger_template: template,
      workspace: workspace,
      subject_type: "Workspace",
      subject_id: workspace.id,
      dimension_type: "summary",
      dimension_id: nil,
      window_range: window_range,
      baseline_range: baseline_range,
      stats: stats,
      severity: severity
    )
  rescue => e
    Rails.logger.warn("[Admin::PromptsController] exec summary fallback candidate failed: #{e.message}")
    nil
  end

  def build_virtual_insight_from_candidate(candidate)
    return nil unless candidate

    Insight.new(
      workspace: candidate.workspace,
      subject_type: candidate.subject_type,
      subject_id: candidate.subject_id,
      metric_id: metric_id_for_candidate(candidate),
      trigger_template: candidate.trigger_template,
      severity: candidate.severity,
      window_start_at: candidate.window_range&.begin,
      window_end_at: candidate.window_range&.end,
      baseline_start_at: candidate.baseline_range&.begin,
      baseline_end_at: candidate.baseline_range&.end,
      data_payload: { stats: candidate.stats }
    )
  end

  def metric_id_for_candidate(candidate)
    case candidate.dimension_type
    when "metric"
      candidate.dimension_id
    when "submetric"
      Submetric.find_by(id: candidate.dimension_id)&.metric_id
    when "category"
      SignalCategory.includes(:submetric).find_by(id: candidate.dimension_id)&.submetric&.metric_id
    else
      nil
    end
  end

  def template_prompt_key(template)
    "insight_template:#{template.key}"
  end

  def default_insight_prompt_text
    @default_insight_prompt_text ||= Insights::CandidatePersister.new(candidates: [], notify: false).send(:default_system_prompt)
  end

  def default_overview_prompt_text
    Clara::OverviewGenerator.new(
      overview: ClaraOverview.new(workspace: Workspace.new, metric: Metric.new, status: :pending),
      workspace: Workspace.new,
      metric: Metric.new,
      stream_key: "noop",
      range_start: Date.current,
      range_end: Date.current,
      member_ids: nil
    ).send(:default_system_prompt)
  end

  def default_ai_chat_prompt_text
    AiChat::Prompts.default_system_prompt
  end
end
