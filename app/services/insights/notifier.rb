require "net/http"
require "erb"
require "faraday"

module Insights
  class Notifier
    def initialize(insight:, candidate:, logger: Rails.logger)
      @insight = insight
      @candidate = candidate
      @logger = logger
    end

    def deliver!
      sent_any = false

      recipients.each do |recipient|
        channels = enabled_channels(recipient)
        next if channels.empty?

        channels.each do |channel|
          delivery = InsightDelivery.create!(
            insight: insight,
            user: recipient.user,
            channel: channel,
            status: "pending",
            metadata: {
              account_type: recipient.account_type,
              type_key: recipient.type_key
            }
          )

          begin
            ok = deliver_channel(channel: channel, recipient: recipient, delivery: delivery)
            if ok
              delivery.update!(status: "sent", delivered_at: Time.current)
              sent_any = true
            else
              delivery.update!(status: "failed")
            end
          rescue => e
            delivery.update!(status: "failed", error_message: e.message)
            logger.error("[Insights::Notifier] delivery error channel=#{channel} user=#{recipient.user&.id} insight=#{insight.id} err=#{e.class}: #{e.message}")
          end
        end
      end

      if sent_any
        insight.update_columns(state: "sent", delivered_at: Time.current)
      end
    end

    private

    attr_reader :insight, :candidate, :logger

    Recipient = Struct.new(:user, :account_type, :type_key, :channel_defaults, keyword_init: true)

    def recipients
      case target_type
      when :user
        user_recipient(candidate.subject_id)
      when :group
        group_recipients
      else
        admin_recipients
      end
    end

    def target_type
      scope = candidate.trigger_template&.subject_scopes.to_s
      case scope
      when "user"  then :user
      when "group" then :group
      when "admin" then :admin
      else
        case candidate.subject_type.to_s
        when "User" then :user
        when "Group" then :group
        else :admin
        end
      end
    end

    def user_recipient(user_id)
      user = User.find_by(id: user_id)
      return [] unless user

      wu = WorkspaceUser.find_by(workspace_id: insight.workspace_id, user_id: user.id)
      [Recipient.new(user: user, account_type: wu&.account_type || "user", type_key: "personal_insights", channel_defaults: channel_defaults_for("user"))]
    end

    def group_recipients
      group = Group.find_by(id: candidate.subject_id)
      return [] unless group

      group.integration_users.includes(:user).filter_map do |iu|
        next unless iu.user
        wu = WorkspaceUser.find_by(workspace_id: insight.workspace_id, user_id: iu.user_id)
        Recipient.new(
          user: iu.user,
          account_type: wu&.account_type || "user",
          type_key: "my_group_insights",
          channel_defaults: channel_defaults_for("user")
        )
      end
    end

    def admin_recipients
      insight.workspace.workspace_users.includes(:user).filter_map do |wu|
        next unless wu.user
        next unless %w[owner admin].include?(wu.account_type)

        Recipient.new(
          user: wu.user,
          account_type: wu.account_type,
          type_key: "executive_summaries",
          channel_defaults: channel_defaults_for(wu.account_type)
        )
      end
    end

    def channel_defaults_for(account_type)
      perm = WorkspaceNotificationPermission.for(insight.workspace, account_type)
      {
        email: perm.enabled?,
        slack: perm.enabled?,
        teams: perm.enabled?
      }
    end

    def enabled_channels(recipient)
      pref = NotificationPreference.find_by(workspace_id: insight.workspace_id, user_id: recipient.user.id)
      allowed_types = WorkspaceNotificationPermission.for(insight.workspace, recipient.account_type).allowed_types

      type_enabled = pref ? pref.type_enabled?(recipient.type_key, allowed_types: allowed_types, default: allowed_types.include?(recipient.type_key)) :
                            allowed_types.include?(recipient.type_key)
      return [] unless type_enabled

      NotificationPreference::CHANNEL_KEYS.filter do |channel|
        enabled = if pref
                    pref.channel_enabled?(channel, default: recipient.channel_defaults[channel.to_sym])
                  else
                    recipient.channel_defaults[channel.to_sym]
                  end

        enabled && channel_available?(channel)
      end
    end

    def deliver_channel(channel:, recipient:, delivery:)
      case channel
      when "email"
        deliver_email(recipient, delivery)
      when "slack"
        deliver_slack(recipient, delivery)
      when "teams"
        deliver_teams(recipient, delivery)
      else
        false
      end
    end

    def deliver_email(recipient, delivery)
      user = recipient.user
      return false unless user&.email.present?

      mail = InsightsMailer.insight_notification(recipient: user, insight: insight)
      mail.deliver_now

      delivery.update!(provider_message_id: mail.message_id)
      logger.info("[Insights::Notifier] Email to user=#{user.id} insight=#{insight.id}")
      true
    rescue => e
      delivery.update!(error_message: e.message)
      logger.error("[Insights::Notifier] Email failed user=#{user&.id} insight=#{insight.id} err=#{e.class}: #{e.message}")
      false
    end

    def deliver_slack(recipient, delivery)
      integration = insight.workspace.integrations.find_by(kind: "slack")
      unless integration
        delivery.update!(error_message: "No Slack integration")
        return false
      end

      iu = integration.integration_users.find_by(user_id: recipient.user.id)
      unless iu&.slack_user_id.present?
        delivery.update!(error_message: "No Slack user mapping")
        return false
      end

      token = slack_bot_token(integration: integration, iu: iu)
      unless token
        delivery.update!(error_message: "No Slack bot token available")
        return false
      end

      svc = Slack::Service.new(token)
      channel_resp = svc.conversations_open(users: iu.slack_user_id)
      channel_id = channel_resp.respond_to?(:channel) ? channel_resp.channel&.id : channel_resp.dig("channel", "id")
      unless channel_id
        delivery.update!(error_message: "Could not open DM channel")
        return false
      end

      text = slack_message_text(insight)
      resp = svc.chat_postMessage(channel: channel_id, text: text)
      ts = resp.respond_to?(:ts) ? resp.ts : resp["ts"]

      delivery.update!(provider_message_id: ts, metadata: delivery.metadata.merge(channel_id: channel_id))
      logger.info("[Insights::Notifier] Slack to user=#{recipient.user.id} insight=#{insight.id} channel=#{channel_id}")
      true
    rescue => e
      delivery.update!(error_message: e.message)
      logger.error("[Insights::Notifier] Slack failed user=#{recipient.user&.id} insight=#{insight.id} err=#{e.class}: #{e.message}")
      false
    end

    def slack_bot_token(integration:, iu:)
      candidates = []
      candidates << iu.slack_bot_token if iu&.slack_bot_token.present?
      candidates += integration.integration_users.where.not(slack_bot_token: nil).pluck(:slack_bot_token)
      candidates.map(&:to_s).find { |tok| tok.start_with?("xoxb") }
    end

    def deliver_teams(recipient, delivery)
      integration = insight.workspace.integrations.find_by(kind: "microsoft_teams")
      unless integration
        delivery.update!(error_message: "No Teams integration")
        return false
      end

      iu = integration.integration_users.where.not(ms_refresh_token: nil).find_by(user_id: recipient.user.id) ||
           integration.integration_users.where.not(ms_refresh_token: nil).first
      unless iu
        delivery.update!(error_message: "No Teams token available")
        return false
      end

      token = refresh_teams_token(iu)
      unless token
        delivery.update!(error_message: "Unable to refresh Teams token")
        return false
      end

      team = integration.teams.first
      channel = integration.channels.first
      unless team && channel
        delivery.update!(error_message: "No Teams channel available")
        return false
      end

      url = "#{Teams::HistorySyncService::GRAPH_BASE}/teams/#{team.ms_team_id}/channels/#{channel.external_channel_id}/messages"
      body = {
        "body" => {
          "contentType" => "html",
          "content" => teams_message_html(insight)
        }
      }

      res = teams_http_post(url, token, body)
      if res && res["id"].present?
        delivery.update!(provider_message_id: res["id"], metadata: delivery.metadata.merge(channel_id: channel.id))
        logger.info("[Insights::Notifier] Teams to user=#{recipient.user.id} insight=#{insight.id} channel=#{channel.id}")
        true
      else
        delivery.update!(error_message: "Teams send failed #{res}")
        false
      end
    rescue => e
      delivery.update!(error_message: e.message)
      logger.error("[Insights::Notifier] Teams failed user=#{recipient.user&.id} insight=#{insight.id} err=#{e.class}: #{e.message}")
      false
    end

    def slack_message_text(insight)
      title = insight.summary_title.presence || insight.trigger_template&.name || "New insight"
      body  = insight.summary_body.presence || insight.data_payload.to_json
      url   = ENV["INSIGHT_DASHBOARD_URL"]

      [title, body, ("View: #{url}" if url.present?)].compact.join("\n\n")
    end

    def teams_message_html(insight)
      title = insight.summary_title.presence || insight.trigger_template&.name || "New insight"
      body  = insight.summary_body.presence || insight.data_payload.to_json
      url   = ENV["INSIGHT_DASHBOARD_URL"]
      link  = url.present? ? "<p><a href=\"#{ERB::Util.html_escape(url)}\">View in Workspace</a></p>" : ""

      "<h3>#{ERB::Util.html_escape(title)}</h3><p>#{ERB::Util.html_escape(body)}</p>#{link}"
    end

    def refresh_teams_token(iu)
      return iu.ms_access_token if iu.ms_access_token.present? && iu.ms_expires_at.present? && iu.ms_expires_at > 5.minutes.from_now

      uri  = URI(Integration::MS_TOKEN_URL)
      body = {
        client_id:     ENV.fetch("TEAMS_CLIENT_ID"),
        client_secret: ENV.fetch("TEAMS_CLIENT_SECRET"),
        grant_type:    "refresh_token",
        refresh_token: iu.ms_refresh_token
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Rails.env.development?

      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(body)
      res  = http.request(req)
      data = JSON.parse(res.body) rescue {}

      unless res.is_a?(Net::HTTPSuccess) && data["access_token"].present?
        logger.error "[Insights::Notifier] Teams token refresh failed for iu=#{iu.id}: #{res.code} #{data}"
        return nil
      end

      iu.update!(
        ms_access_token:  data["access_token"],
        ms_refresh_token: data["refresh_token"].presence || iu.ms_refresh_token,
        ms_expires_at:    Time.current + data["expires_in"].to_i.seconds
      )

      iu.ms_access_token
    end

    def teams_http_post(url, token, body)
      conn = Faraday.new do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end

      res = conn.post(url) do |req|
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["Accept"]        = "application/json"
        req.headers["Content-Type"]  = "application/json"
        req.body = body.to_json
      end

      return res.body if res.status.between?(200, 299)

      logger.warn("[Insights::Notifier] Teams POST #{url} failed: #{res.status} #{res.body}")
      nil
    end

    def channel_available?(channel)
      case channel
      when "teams"
        workspace_integration_kinds.include?("microsoft_teams")
      when "slack"
        workspace_integration_kinds.include?("slack")
      else
        true
      end
    end

    def workspace_integration_kinds
      @workspace_integration_kinds ||= insight.workspace.integrations.pluck(:kind)
    end
  end
end
