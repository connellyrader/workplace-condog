# app/controllers/webhooks/slack_events_controller.rb
require "openssl"

class Webhooks::SlackEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_user!
  skip_before_action :lucas_only

  before_action :verify_slack_webhook_signature!

  def receive
    head :ok
    # raw = request.raw_post
    # #INSECURE #Rails.logger.info("RECEIVING PAYLOAD: #{raw}")
    #
    # payload = JSON.parse(raw) rescue {}
    #
    # case payload["type"]
    # when "url_verification"
    #   render json: { challenge: payload["challenge"] }
    #
    # when "event_callback"
    #   begin
    #     event   = payload["event"] || {}
    #     team_id = payload["team_id"] || payload.dig("authorizations", 0, "team_id")
    #
    #     if event["type"] == "message" && event["subtype"].blank? && event["text"].to_s.strip.present?
    #       persist_message!(team_id: team_id, event: event) # ← only persist
    #     end
    #
    #     head :ok
    #   rescue => e
    #     Rails.logger.error("SlackEventsController error: #{e.class} #{e.message}")
    #     Rails.logger.error(e.backtrace.first(10).join("\n"))
    #     head :ok
    #   end
    #
    # else
    #   render json: { error: "unsupported_type" }, status: :bad_request
    # end
  end

  private

  def persist_message!(team_id:, event:)
    # integration = Integration.find_by!(slack_team_id: team_id)
    #
    # slack_user_id = event["user"].to_s
    # slack_channel = event["channel"].to_s
    # slack_ts      = event["ts"].to_s
    # text          = event["text"].to_s
    #
    # channel = Channel.find_or_create_by!(integration_id: integration.id, external_channel_id: slack_channel)
    # iu      = IntegrationUser.find_or_create_by!(integration_id: integration.id, slack_user_id: slack_user_id)
    #
    # posted_at = slack_ts.include?(".") ? Time.at(slack_ts.to_f).utc : Time.at(slack_ts.to_i).utc
    #
    # msg = Message.find_or_initialize_by(integration_id: integration.id, channel_id: channel.id, slack_ts: slack_ts)
    # msg.assign_attributes(
    #   integration_user_id: iu.id,
    #   text:              text,
    #   posted_at:         posted_at,
    #   processed:         false,           # ← ensure it’s queued for later
    #   processed_at:      nil,
    #   sent_for_inference_at: nil
    # )
    # msg.save!
    # msg
  end

  def verify_slack_webhook_signature!
    secret = ENV["SLACK_SIGNING_SECRET"].to_s
    if secret.blank?
      Rails.logger.error "[SlackWebhook] missing SLACK_SIGNING_SECRET; rejecting request"
      return head :service_unavailable
    end

    timestamp = request.headers["X-Slack-Request-Timestamp"].to_s
    signature = request.headers["X-Slack-Signature"].to_s
    raw = request.raw_post.to_s

    if timestamp.blank? || signature.blank?
      Rails.logger.warn "[SlackWebhook] missing signature headers"
      return head :unauthorized
    end

    ts = Integer(timestamp) rescue nil
    if ts.nil? || (Time.now.to_i - ts).abs > 5.minutes.to_i
      Rails.logger.warn "[SlackWebhook] stale/invalid timestamp"
      return head :unauthorized
    end

    basestring = "v0:#{timestamp}:#{raw}"
    expected = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", secret, basestring)

    unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)
      Rails.logger.warn "[SlackWebhook] invalid signature"
      return head :unauthorized
    end
  end
end
