class ClaraOverviewChannel < ApplicationCable::Channel
  def subscribed
    @workspace = current_user.workspaces.find_by(id: params[:workspace_id])
    @metric    = Metric.find_by(id: params[:metric_id])
    @range_start = parse_date(params[:range_start])
    @range_end   = parse_date(params[:range_end])
    @group_scope = params[:group_scope].presence || "all"

    reject unless @workspace && @metric && @range_start && @range_end

    stream_from stream_key

    member_ids, serialized_group_scope = resolve_group_scope(@group_scope)
    @group_scope = serialized_group_scope

    service = Clara::OverviewService.new(
      workspace: @workspace,
      metric:    @metric,
      user:      current_user,
      range_start: @range_start,
      range_end:   @range_end,
      group_scope: serialized_group_scope,
      member_ids:  member_ids
    )

    unless service.data_available?(min_detections: Clara::OverviewService::MIN_DETECTIONS)
      transmit({ type: "no_data" })
      return
    end

    if (latest = service.latest)
      transmit({ type: "prefill", overview: Clara::OverviewService.serialize(latest) })
    end

    service.ensure_generation!(stream_key: stream_key)
  end

  private

  def stream_key
    "clara_overview:ws:#{@workspace.id}:metric:#{@metric.id}:from:#{@range_start}:to:#{@range_end}:group:#{@group_scope}"
  end

  def parse_date(val)
    return val.to_date if val.respond_to?(:to_date)
    Date.parse(val.to_s) rescue nil
  end

  def resolve_group_scope(scope_param)
    groups = @workspace.groups
    return [nil, nil] if groups.empty?

    str = scope_param.to_s
    if str == "all" || str == "all_groups"
      member_ids = groups.includes(:group_members).flat_map { |g| g.group_members.pluck(:integration_user_id) }.uniq
      return [member_ids, "all_groups"]
    end

    if str.start_with?("group:")
      gid = str.split(":", 2)[1]
      return resolve_specific_group(groups, gid)
    end

    resolve_specific_group(groups, str)
  end

  def resolve_specific_group(groups, gid)
    return [nil, nil] unless gid.present?
    if (grp = groups.find_by(id: gid))
      return [grp.integration_user_ids, "group:#{grp.id}"]
    end
    [nil, nil]
  end
end
