module Slack
  class ChannelMessageCounter
    RATE_LIMIT_SLEEP = (ENV["SLACK_CHANNEL_COUNT_SLEEP"] || "0").to_f

    def initialize(integration)
      @integration = integration
    end

    def count_all_channels!
      iu = @integration.integration_users.where.not(slack_history_token: nil).first
      return unless iu

      svc = Slack::Service.new(iu.slack_history_token)

      # Count ALL channel types — public, private, mpim, im (prioritize public first)
      channels = @integration.channels.where(is_archived: false)
      channels = channels.order(Arel.sql("CASE channels.kind WHEN 'public_channel' THEN 0 WHEN 'private_channel' THEN 1 WHEN 'mpim' THEN 2 WHEN 'im' THEN 3 ELSE 4 END"))

      range_end = Time.current
      range_start = 60.days.ago

      channels.find_each do |channel|
        query = build_query(channel, range_start, range_end)
        next if query.nil? # skip if we can't build a valid query

        begin
          resp = svc.search_messages(query: query, count: 1)
          total = resp&.dig('messages', 'total') || resp&.dig(:messages, :total)
          channel.update!(
            estimated_message_count: total.to_i,
            message_count_estimated_at: Time.current
          )
        rescue Slack::Web::Api::Errors::TooManyRequests => e
          retry_after = e.respond_to?(:retry_after) ? e.retry_after.to_i : 3
          retry_after = 3 if retry_after <= 0
          Rails.logger.warn("[ChannelMessageCounter] Rate limited for channel #{channel.id}; sleeping #{retry_after}s")
          sleep retry_after
          retry
        rescue => e
          Rails.logger.warn("[ChannelMessageCounter] Failed for channel #{channel.id} (#{channel.kind}): #{e.class}: #{e.message}")
          # Don't stop — continue counting other channels
        end

        sleep RATE_LIMIT_SLEEP if RATE_LIMIT_SLEEP > 0
      end
    end

    private

    def build_query(channel, range_start, range_end)
      start_date = range_start.to_date.to_s
      end_date = range_end.to_date.to_s

      case channel.kind
      when "public_channel", "private_channel"
        # in:#channel-name or in:channel-name
        name = channel.name.to_s.strip
        return nil if name.blank?
        "in:#{name} after:#{start_date} before:#{end_date}"
      when "mpim"
        # MPIMs use the group name directly
        name = channel.name.to_s.strip
        return nil if name.blank?
        "in:#{name} after:#{start_date} before:#{end_date}"
      when "im"
        # DMs: search using in:<@UserID> — the channel name IS the user ID for IMs
        user_id = channel.name.to_s.strip
        return nil if user_id.blank?
        "in:<@#{user_id}> after:#{start_date} before:#{end_date}"
      else
        nil
      end
    end
  end
end
