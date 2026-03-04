# slack_event_fetcher.rb
# Slack event API will send events to AWS Lamda and Lamda then stores them in AWS S3 where they wait for this service to ingests the Slack event payloads: parses events into Messages and related metadata,
# upserts channels/users as needed, and advances ingestion state without requiring live webhook processing.

module Slack
  class EventFetcher
    AWS_REGION    = ENV.fetch("AWS_REGION", "us-east-2")
    EVENTS_BUCKET = ENV.fetch("SLACK_EVENTS_BUCKET")
    EVENTS_PREFIX = ENV.fetch("SLACK_EVENTS_PREFIX", "slack-events/incoming/") # trailing slash on purpose
    DEFAULT_LIMIT = 50

    def self.call(limit: DEFAULT_LIMIT) = new.call(limit: limit)

    def initialize
      @s3 = Aws::S3::Client.new(region: AWS_REGION,
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )
    end

    def call(limit:)
      keys      = pick_oldest_keys(limit)
      processed = 0

      keys.each do |key|
        begin
          payload = get_json(key)
          handled = handle_payload!(payload)
          delete_object(key) if handled
          processed += 1 if handled
        rescue JSON::ParserError => e
          Rails.logger.warn("[SlackEventFetcher] invalid JSON s3://#{EVENTS_BUCKET}/#{key}: #{e.message}")
          delete_object(key)
        rescue => e
          Rails.logger.error("[SlackEventFetcher] #{key} failed: #{e.class} #{e.message}")
          Rails.logger.error(e.backtrace.first(5).join("\n")) if e.backtrace
        end
      end

      Rails.logger.info("[SlackEventFetcher] processed #{processed}/#{keys.size} (bucket=#{EVENTS_BUCKET} prefix=#{EVENTS_PREFIX})")
      processed
    end

    private

    def handle_payload!(payload)
      unless payload.is_a?(Hash)
        Rails.logger.warn("[SlackEventFetcher] unexpected payload shape: #{payload.class}")
        return true
      end

      case payload["type"]
      when "url_verification"
        true # nothing to persist, but the file is handled
      when "event_callback"
        event   = payload["event"] || {}
        team_id = payload["team_id"] || payload.dig("authorizations", 0, "team_id")

        if team_id.blank?
          Rails.logger.warn("[SlackEventFetcher] missing team_id in payload, skipping")
          return true
        end

        process_message_event!(team_id, event)
      else
        Rails.logger.info("[SlackEventFetcher] skipping unsupported payload type=#{payload['type'].inspect}")
        true
      end
    end

    def process_message_event!(team_id, event)
      return true unless event["type"] == "message"

      # Humans only: skip any message subtype (bot_message, message_changed, etc.)
      # If you want edits/deletes later, handle them explicitly, but do not ingest them as new messages.
      return true if event["subtype"].present?

      # Humans only: must have a real user id
      slack_user_id = event["user"].to_s
      return true if slack_user_id.blank?

      # Extra safety: skip bot/app indicators even if subtype is absent
      return true if event["bot_id"].present? || event["bot_profile"].present?

      raw_text = event["text"].to_s
      text = ::Messages::PiiScrubber.scrub(raw_text).strip
      return true if text.blank?

      if word_count(text) < 5
        Rails.logger.info("[SlackEventFetcher] skipped_short_text_lt_5 team_id=#{team_id} channel=#{event['channel']} slack_ts=#{event['ts']}")
        return true
      end

      slack_channel = event["channel"].to_s
      if slack_channel.blank?
        Rails.logger.warn("[SlackEventFetcher] missing channel in event for team_id=#{team_id}, skipping")
        return true
      end

      slack_ts = event["ts"].presence || Time.now.to_f.to_s

      # Find ALL ACTIVE integrations for this Slack workspace (not just most recent)
      # This allows one Slack workspace to feed multiple Workplace accounts,
      # while preventing archived workspaces from ingesting new messages.
      integrations = Integration
        .joins(:workspace)
        .where(kind: "slack", slack_team_id: team_id)
        .where(workspaces: { archived_at: nil })
        .to_a

      if integrations.empty?
        Rails.logger.warn("[SlackEventFetcher] no integrations found for team_id=#{team_id}, dropping event")
        return true
      end

      Rails.logger.info("[SlackEventFetcher] team_id=#{team_id} has #{integrations.size} integration(s)") if integrations.size > 1

      # Translate ONCE (same text for all integrations)
      translation = ::Messages::Translator.translate(text)

      posted_at =
        if slack_ts.include?(".") then Time.at(slack_ts.to_f).utc
        else                          Time.at(slack_ts.to_i).utc
        end

      # Create a message for EACH integration
      integrations.each do |integration|
        persist_message_for_integration!(
          integration:   integration,
          event:         event,
          slack_user_id: slack_user_id,
          slack_channel: slack_channel,
          slack_ts:      slack_ts,
          posted_at:     posted_at,
          translation:   translation,
          raw_text:      raw_text
        )
      end

      true
    end

    def persist_message_for_integration!(integration:, event:, slack_user_id:, slack_channel:, slack_ts:, posted_at:, translation:, raw_text:)
      channel, new_channel = find_or_create_channel!(integration, slack_channel)
      hydrate_channel_from_api!(integration, channel) if new_channel || channel_needs_hydration?(channel)

      iu = IntegrationUser.find_or_create_by!(integration_id: integration.id, slack_user_id: slack_user_id) do |u|
        u.is_bot = false if u.respond_to?(:is_bot=)
      end

      # Domain-level safety: do not ingest if the user is flagged as a bot
      return if iu.respond_to?(:is_bot?) && iu.is_bot?

      msg = Message.find_or_initialize_by(integration_id: integration.id, channel_id: channel.id, slack_ts: slack_ts)
      raw_text_in_subtype = raw_text

      msg.assign_attributes(
        integration_user_id:   iu.id,
        text:                  translation[:text],           # Always English
        text_original:         translation[:text_original],  # Original if non-English, nil otherwise
        original_language:     translation[:original_language],
        subtype:               raw_text_in_subtype,
        posted_at:             posted_at,
        processed:             false,
        processed_at:          nil,
        sent_for_inference_at: nil
      )
      msg.slack_thread_ts = event["thread_ts"].to_s if msg.respond_to?(:slack_thread_ts=) && event["thread_ts"]
      msg.save!
    rescue => e
      Rails.logger.error("[SlackEventFetcher] failed to persist message for integration=#{integration.id}: #{e.class} #{e.message}")
    end


    # ---- S3 helpers ----
    def pick_oldest_keys(limit)
      got, token = [], nil

      while got.size < limit
        resp = @s3.list_objects_v2(bucket: EVENTS_BUCKET, prefix: EVENTS_PREFIX, continuation_token: token)
        (resp.contents || []).sort_by(&:last_modified).each do |obj|
          got << obj.key
          break if got.size >= limit
        end
        break unless resp.is_truncated && got.size < limit
        token = resp.next_continuation_token
      end

      got
    end

    def get_json(key)
      resp = @s3.get_object(bucket: EVENTS_BUCKET, key: key)
      body = resp.body.read

      if resp.content_encoding.to_s.downcase.include?("gzip")
        body = Zlib::GzipReader.new(StringIO.new(body)).read
      end

      JSON.parse(body)
    end

    def find_or_create_channel!(integration, slack_channel)
      identity = ChannelIdentity.find_by(
        integration_id:      integration.id,
        provider:            "slack",
        external_channel_id: slack_channel
      )

      if identity
        identity.update!(last_seen_at: Time.current)
        return [identity.channel, false]
      end

      channel = integration.channels.find_or_initialize_by(external_channel_id: slack_channel)
      new_channel = channel.new_record?
      channel.save! if new_channel

      ChannelIdentity.find_or_create_by!(
        integration:         integration,
        channel:             channel,
        provider:            "slack",
        external_channel_id: slack_channel
      ) do |ci|
        ci.discovered_at = Time.current
        ci.last_seen_at  = Time.current
      end

      [channel, new_channel]
    end

    def channel_needs_hydration?(channel)
      channel.name.blank? ||
        channel.channel_memberships.empty? ||
        channel.created_unix.nil? ||
        channel.is_shared.nil?
    end



    def hydrate_channel_from_api!(integration, channel)
      iu = integration.integration_users.where.not(slack_history_token: nil).order(:id).first
      unless iu
        mark_channel_unreachable!(channel, "no_token_available")
        return
      end

      svc = Slack::Service.new(iu.slack_history_token)
      begin
        slack_id = channel.slack_external_id_for(integration_user: iu)
        if slack_id.blank?
          mark_channel_unreachable!(channel, "blank_slack_id")
          return
        end
        info = svc.conversations_info(channel: slack_id)
        raw  = info.channel

        unless raw
          mark_channel_unreachable!(channel, "no_channel_info")
          return
        end

        apply_channel_attributes!(channel, raw)
        hydrate_channel_members!(integration, channel, svc, slack_channel_id: slack_id)
      rescue Slack::Web::Api::Errors::NotInChannel, Slack::Web::Api::Errors::MissingScope => e
        mark_channel_unreachable!(channel, e.class.name)
      rescue Slack::Web::Api::Errors::ChannelNotFound => e
        mark_channel_unreachable!(channel, "channel_not_found")
      rescue Slack::Web::Api::Errors::SlackError => e
        Rails.logger.warn("[SlackEventFetcher] hydration failed...")
        # Don't mark unreachable for transient errors
      end
    end

    # NEW METHOD:
    def mark_channel_unreachable!(channel, reason)
      Rails.logger.info("[SlackEventFetcher] marking channel unreachable channel=#{channel.id} reason=#{reason}")
      channel.update!(
        history_unreachable: true,
        backfill_complete: true,
        last_history_status: "unreachable_#{reason}",
        last_history_error: reason
      )
    end

    def apply_channel_attributes!(channel, raw)
      kind =
        if raw["is_im"] then "im"
        elsif raw["is_mpim"] then "mpim"
        elsif raw["is_private"] then "private_channel"
        else "public_channel"
        end

      channel.kind = kind
      channel.name ||= (raw["name"] || raw["user"])
      channel.is_private = !!raw["is_private"] if channel.has_attribute?(:is_private)
      channel.is_archived = !!raw["is_archived"] if channel.has_attribute?(:is_archived)
      channel.is_shared = !!raw["is_shared"] if channel.has_attribute?(:is_shared)
      channel.created_unix ||= raw["created"]

      channel.save! if channel.changed?
    end

    def hydrate_channel_members!(integration, channel, svc, slack_channel_id:)
      return if slack_channel_id.blank?

      cursor = nil
      loop do
        resp = svc.conversations_members(channel: slack_channel_id, limit: 200, cursor: cursor)

        (resp.members || []).each do |slack_uid|
          slack_uid = slack_uid.to_s
          next if slack_uid.blank?

          iu = integration.integration_users.find_or_create_by!(slack_user_id: slack_uid)
          if iu.has_attribute?(:is_bot) && iu.is_bot == false && bot_like_slack_id?(slack_uid)
            iu.update!(is_bot: true)
          end

          ChannelMembership.find_or_create_by!(
            integration:      integration,
            channel:          channel,
            integration_user: iu
          )
        end

        cursor = resp.response_metadata&.next_cursor
        break if cursor.blank?
      end
    rescue Slack::Web::Api::Errors::NotInChannel, Slack::Web::Api::Errors::MissingScope
      # Membership hydration is best-effort.
    end

    def bot_like_slack_id?(slack_user_id)
      sid = slack_user_id.to_s
      return true if sid.start_with?("bot:")
      return true if sid == "USLACKBOT"
      return true if sid.match?(/\A[BW][A-Z0-9]+\z/)
      false
    end

    def word_count(text)
      text.to_s.scan(/\b[\p{L}\p{N}'-]+\b/).size
    end

    def delete_object(key)
      @s3.delete_object(bucket: EVENTS_BUCKET, key: key)
    rescue => e
      Rails.logger.warn("[SlackEventFetcher] delete failed s3://#{EVENTS_BUCKET}/#{key}: #{e.class} #{e.message}")
    end
  end
end
