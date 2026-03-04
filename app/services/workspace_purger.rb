class WorkspacePurger
  BATCH_SIZE = 5_000
  TIME_BUDGET_SECONDS = 20

  PauseRequested = Class.new(StandardError)

  def initialize(workspace_id:, request_id: nil, requested_by: nil)
    @workspace_id = workspace_id
    @request_id = request_id || SecureRandom.uuid
    @requested_by = requested_by
  end

  def call
    @started_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    ws = Workspace.find_by(id: @workspace_id)
    return unless ws

    per_ws_lock_key = 947_222
    global_lock_key = 947_223

    got_global_lock = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{global_lock_key})")
    got_global_lock = ActiveModel::Type::Boolean.new.cast(got_global_lock)
    unless got_global_lock
      log(:busy, ws: ws.id, msg: "another workspace purge is running; requeue")
      WorkspacePurgeJob.set(wait: 2.minutes).perform_later(ws.id, request_id: @request_id, requested_by: @requested_by)
      return
    end

    got_lock = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{per_ws_lock_key}, #{ws.id.to_i})")
    got_lock = ActiveModel::Type::Boolean.new.cast(got_lock)
    unless got_lock
      log(:busy, ws: ws.id, msg: "purge already in progress for workspace; requeue")
      WorkspacePurgeJob.set(wait: 2.minutes).perform_later(ws.id, request_id: @request_id, requested_by: @requested_by)
      return
    end

    log(:start, ws: ws.id, archived: ws.archived_at.present?)

    purge_workspace_dependencies!(ws)
    cancel_stripe_for_workspace!(ws)

    log(:done, ws: ws.id)
  rescue PauseRequested
    log(:yield, ws: ws.id, msg: "time budget reached; requeue")
    WorkspacePurgeJob.set(wait: 10.seconds).perform_later(ws.id, request_id: @request_id, requested_by: @requested_by)
  ensure
    if ws&.id
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(947_222, #{ws.id.to_i})") rescue nil
    end
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(947_223)") rescue nil
  end

  private

  def log(stage, **data)
    Rails.logger.info("[WorkspaceDelete][SOC2] stage=#{stage} rid=#{@request_id} requested_by=#{@requested_by} #{data.map { |k, v| "#{k}=#{v}" }.join(' ')}")
  end

  def delete_in_batches(scope, label)
    total = 0
    scope.in_batches(of: BATCH_SIZE) do |rel|
      maybe_pause!
      deleted = rel.delete_all
      total += deleted
    end
    log(:batch_delete, label: label, deleted: total)
    total
  end

  def maybe_pause!
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_mono.to_f
    raise PauseRequested if elapsed >= TIME_BUDGET_SECONDS
  end

  def purge_workspace_dependencies!(ws)
    ws_id = ws.id

    integration_ids      = Integration.where(workspace_id: ws_id).select(:id)
    group_ids            = Group.where(workspace_id: ws_id).select(:id)
    insight_ids          = Insight.where(workspace_id: ws_id).select(:id)
    conversation_ids     = ::AiChat::Conversation.where(workspace_id: ws_id).select(:id)
    clara_overview_ids   = ClaraOverview.where(workspace_id: ws_id).select(:id)

    insight_pipeline_run_ids = InsightPipelineRun.where(workspace_id: ws_id).select(:id)
    workspace_template_override_ids = WorkspaceInsightTemplateOverride.where(workspace_id: ws_id).select(:id)

    team_ids             = Team.where(integration_id: integration_ids).select(:id)
    channel_ids          = Channel.where(integration_id: integration_ids).select(:id)
    integration_user_ids = IntegrationUser.where(integration_id: integration_ids).select(:id)
    message_ids          = Message.where(integration_id: integration_ids).select(:id)
    model_test_ids       = ModelTest.where(integration_id: integration_ids).select(:id)

    begin
      ws.icon.purge_later if ws.icon.attached?
    rescue => e
      log(:warn, ws: ws_id, msg: "icon purge enqueue failed #{e.class}: #{e.message}")
    end

    log(:step_start, ws: ws_id, step: "ai_chat")
    delete_in_batches(::AiChat::Message.where(ai_chat_conversation_id: conversation_ids), "ai_chat_messages")
    delete_in_batches(::AiChat::Conversation.where(id: conversation_ids), "ai_chat_conversations")

    delete_in_batches(ClaraOverview.where(id: clara_overview_ids), "clara_overviews")

    delete_in_batches(NotificationPreference.where(workspace_id: ws_id), "notification_preferences")
    delete_in_batches(WorkspaceNotificationPermission.where(workspace_id: ws_id), "workspace_notification_permissions")
    delete_in_batches(InsightPipelineRun.where(id: insight_pipeline_run_ids), "insight_pipeline_runs")
    delete_in_batches(WorkspaceInsightTemplateOverride.where(id: workspace_template_override_ids), "workspace_template_overrides")

    log(:step_start, ws: ws_id, step: "insights")
    delete_in_batches(InsightDelivery.where(insight_id: insight_ids), "insight_deliveries")
    delete_in_batches(InsightDriverItem.where(insight_id: insight_ids), "insight_driver_items")
    delete_in_batches(Insight.where(id: insight_ids), "insights")
    delete_in_batches(InsightPipelineRun.where(workspace_id: ws_id), "insight_pipeline_runs_workspace")

    delete_in_batches(WorkspaceInvite.where(workspace_id: ws_id), "workspace_invites_workspace")

    log(:step_start, ws: ws_id, step: "memberships")
    delete_in_batches(TeamMembership.where(team_id: team_ids), "team_memberships_team")
    delete_in_batches(TeamMembership.where(integration_user_id: integration_user_ids), "team_memberships_user")
    delete_in_batches(ChannelMembership.where(channel_id: channel_ids), "channel_memberships_channel")
    delete_in_batches(ChannelMembership.where(integration_id: integration_ids), "channel_memberships_integration")
    delete_in_batches(ChannelMembership.where(integration_user_id: integration_user_ids), "channel_memberships_user")

    delete_in_batches(GroupMember.where(group_id: group_ids), "group_members_group")
    delete_in_batches(GroupMember.where(integration_user_id: integration_user_ids), "group_members_user")
    delete_in_batches(Group.where(id: group_ids), "groups")

    log(:step_start, ws: ws_id, step: "inference_artifacts")
    delete_in_batches(Detection.where(message_id: message_ids), "detections_by_message")
    delete_in_batches(Detection.where(model_test_id: model_test_ids), "detections_by_model_test")
    delete_in_batches(ModelTestDetection.where(message_id: message_ids), "model_test_detections_by_message")
    delete_in_batches(AsyncInferenceResult.where(message_id: message_ids), "async_inference_results_by_message")
    delete_in_batches(AsyncInferenceResult.where(model_test_id: model_test_ids), "async_inference_results_by_model_test")
    delete_in_batches(ModelTestDetection.where(model_test_id: model_test_ids), "model_test_detections_by_model_test")
    delete_in_batches(ModelTest.where(id: model_test_ids), "model_tests")

    log(:step_start, ws: ws_id, step: "messages")
    delete_in_batches(ReferenceMention.where(message_id: message_ids), "reference_mentions")
    delete_in_batches(Message.where(id: message_ids), "messages")

    delete_in_batches(ChannelIdentity.where(channel_id: channel_ids), "channel_identities_channel")
    delete_in_batches(ChannelIdentity.where(integration_id: integration_ids), "channel_identities_integration")
    delete_in_batches(ChannelIdentity.where(integration_user_id: integration_user_ids), "channel_identities_user")

    delete_in_batches(Channel.where(id: channel_ids), "channels")
    delete_in_batches(Team.where(id: team_ids), "teams")

    log(:step_start, ws: ws_id, step: "integration_users")
    delete_in_batches(WorkspaceInvite.where(integration_user_id: integration_user_ids), "workspace_invites_integration_user")
    delete_in_batches(IntegrationUser.where(id: integration_user_ids), "integration_users")

    delete_in_batches(
      WorkspaceUser
        .where(workspace_id: ws_id)
        .where.not("is_owner = ? OR role = ? OR user_id = ?", true, "owner", ws.owner_id),
      "workspace_users_non_owner"
    )

    delete_in_batches(InsightDetectionRollup.where(workspace_id: ws_id), "insight_detection_rollups")
    delete_in_batches(WorkspaceInsightTemplateOverride.where(workspace_id: ws_id), "workspace_template_overrides_workspace")

    delete_in_batches(Integration.where(id: integration_ids), "integrations")
  end

  def cancel_stripe_for_workspace!(ws)
    ws.subscriptions
      .where.not(stripe_subscription_id: [nil, ""])
      .find_each do |sub|

      next if sub.status.to_s == "canceled"

      sid = sub.stripe_subscription_id.to_s
      next if sid.blank?

      begin
        Stripe::Subscription.cancel(sid)
      rescue Stripe::InvalidRequestError => e
        log(:info, ws: ws.id, msg: "stripe sub #{sid} not cancelable: #{e.message}")
      end

      begin
        sub.update!(status: "canceled")
      rescue => e
        log(:warn, ws: ws.id, msg: "stripe local status update failed #{e.class}: #{e.message}")
      end
    end
  end
end
