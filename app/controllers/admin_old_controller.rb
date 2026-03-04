class AdminOldController < ApplicationController
  layout "admin"

  before_action :authenticate_admin

  def index
    @total_users = User.count
    @recent_users = User.where('created_at > ?', 7.days.ago).count

    render "admin_old/index"
  end

  def models
    @models = Model.includes(:aws_instance).order(:name)
    @aws_instances = AwsInstance.order(Arel.sql("hourly_price NULLS LAST"), :instance_type)

    render "admin/models/index"
  end

  def insights
    @lookback_days    = 30
    @templates        = InsightTriggerTemplate.enabled.order(:key)
    @recent_insights  = Insight.includes(:trigger_template, :workspace, :subject)
                               .order(Arel.sql("COALESCE(window_end_at, created_at) DESC"))
                               .limit(20)
    @selected_insight = @recent_insights.first

    if @selected_insight
      @notification_preview = notification_preview_for(@selected_insight)
      @evidence_samples     = evidence_samples_for(@selected_insight, limit: 5)
    else
      @notification_preview = []
      @evidence_samples     = []
    end
  end

  private

  helper_method :subject_label
  helper_method :insight_message_info

  def subject_label(record)
    return "Unknown" unless record

    if record.respond_to?(:name) && record.name.present?
      record.name
    elsif record.respond_to?(:full_name) && record.full_name.present?
      record.full_name
    else
      "#{record.class.name} #{record.id}"
    end
  end

  def insight_message_info(insight)
    @insight_message_cache ||= {}
    @insight_message_cache[insight.id] ||= begin
      det = detection_for(insight)
      msg = det&.message
      author_user = msg&.integration_user&.user
      {
        text: msg&.text,
        posted_at: msg&.posted_at,
        author: author_user&.full_name || author_user&.name || msg&.integration_user&.display_name || msg&.integration_user&.real_name || msg&.integration_user&.id
      }
    end
  end

  def detection_for(insight)
    scope = Detection.for_workspace(insight.workspace_id).joins(:message)
    scope = scope.where(metric_id: insight.metric_id) if insight.metric_id.present?

    if insight.window_start_at && insight.window_end_at
      scope = scope.where("COALESCE(messages.posted_at, messages.created_at) BETWEEN ? AND ?",
                          insight.window_start_at, insight.window_end_at)
    end

    scope =
      case insight.subject_type.to_s
      when "User"
        scope.joins(message: { integration_user: :user }).where(integration_users: { user_id: insight.subject_id })
      when "Group"
        scope.joins(message: { integration_user: { group_members: :group } }).where(group_members: { group_id: insight.subject_id })
      else
        scope
      end

    scope.order(Arel.sql("COALESCE(messages.posted_at, messages.created_at) DESC")).first
  end

  def notification_preview_for(insight)
    template = insight.trigger_template
    return [] unless template

    case template.subject_scopes.to_s
    when "user"  then recipients_for_user_insight(insight, type_key: "personal_insights")
    when "group" then recipients_for_group_insight(insight, type_key: "my_group_insights")
    else              recipients_for_admin_insight(insight, type_key: "executive_summaries")
    end
  end

  def recipients_for_user_insight(insight, type_key:)
    user = insight.subject
    return [] unless user.is_a?(User)

    wu = WorkspaceUser.find_by(workspace_id: insight.workspace_id, user_id: user.id)
    account_type = wu&.account_type || "user"
    [recipient_payload(user: user, account_type: account_type, type_key: type_key, workspace: insight.workspace)].compact
  end

  def recipients_for_group_insight(insight, type_key:)
    group = insight.subject
    return [] unless group.is_a?(Group)

    group.integration_users.includes(:user).filter_map do |iu|
      next unless iu.user
      wu = WorkspaceUser.find_by(workspace_id: insight.workspace_id, user_id: iu.user.id)
      account_type = wu&.account_type || "user"
      recipient_payload(user: iu.user, account_type: account_type, type_key: type_key, workspace: insight.workspace)
    end.compact
  end

  def recipients_for_admin_insight(insight, type_key:)
    insight.workspace.workspace_users.includes(:user).filter_map do |wu|
      next unless wu.user
      next unless %w[owner admin].include?(wu.account_type)

      recipient_payload(user: wu.user, account_type: wu.account_type, type_key: type_key, workspace: insight.workspace)
    end.compact
  end

  def recipient_payload(user:, account_type:, type_key:, workspace:)
    perm = WorkspaceNotificationPermission.for(workspace, account_type)
    allowed_types = perm.allowed_types
    type_allowed_default = allowed_types.include?(type_key)

    pref = NotificationPreference.find_by(workspace_id: workspace.id, user_id: user.id)
    type_enabled = if pref
                     pref.type_enabled?(type_key, allowed_types: allowed_types, default: type_allowed_default)
                   else
                     type_allowed_default
                   end

    return nil unless type_enabled

    channel_defaults = {
      email: perm.enabled?,
      slack: perm.enabled?,
      teams: perm.enabled?
    }

    channels = NotificationPreference::CHANNEL_KEYS.map do |channel|
      default = channel_defaults[channel.to_sym]
      enabled = pref ? pref.channel_enabled?(channel, default: default) : default
      {
        key: channel,
        enabled: enabled,
        reason: pref ? (pref.public_send("#{channel}_enabled").nil? ? "default" : "user") : "default"
      }
    end

    {
      user: user,
      account_type: account_type,
      type_key: type_key,
      channels: channels
    }
  end

  def evidence_samples_for(insight, limit:)
    return [] unless insight

    scope = Detection.for_workspace(insight.workspace_id).joins(:message)
    scope = scope.where(metric_id: insight.metric_id) if insight.metric_id.present?

    if insight.window_start_at && insight.window_end_at
      scope = scope.where("COALESCE(messages.posted_at, messages.created_at) BETWEEN ? AND ?",
                          insight.window_start_at, insight.window_end_at)
    end

    scope =
      case insight.subject_type.to_s
      when "User"
        scope.joins(message: { integration_user: :user }).where(integration_users: { user_id: insight.subject_id })
      when "Group"
        scope.joins(message: { integration_user: { group_members: :group } }).where(group_members: { group_id: insight.subject_id })
      else
        scope
      end

    helper = ActionController::Base.helpers

    scope.order(Arel.sql("COALESCE(messages.posted_at, messages.created_at) DESC"))
         .limit(limit)
         .map do |det|
      msg = det.message
      text = helper.strip_tags(msg&.text.to_s)
      {
        posted_at: msg&.posted_at,
        channel_type: msg&.channel&.kind,
        sender_role: msg&.integration_user&.role,
        text: text.truncate(240)
      }
    end
  end
end
