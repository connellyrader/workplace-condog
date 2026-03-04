# slack_token_pool.rb
# Manages a pool of Slack OAuth tokens (bot/user) for ingestion workloads: selects an available token,
# rotates on rate limits, tracks cooldowns, and spreads load across tokens to improve throughput.
module Slack
  class TokenPool
    def initialize(integration:)
      @integration = integration
    end

    def token_for_channel(channel:)
      # Prefer members’ tokens; fallback to any available on this integration
      member_ids = ChannelMembership.where(channel: channel).pluck(:integration_user_id)

      candidates = @integration.integration_users.where(id: member_ids)
      candidates = @integration.integration_users unless candidates.exists?

      candidates = candidates
                     .where.not(slack_history_token: nil)
                     .where("rate_limited_until IS NULL OR rate_limited_until < ?", Time.current)

      iu = candidates.order("random()").first
      return [nil, nil] unless iu

      on_429 = lambda do |retry_after|
        iu.update!(
          rate_limited_until:                 Time.current + retry_after.seconds,
          rate_limit_last_retry_after_seconds: retry_after
        )
      end

      [iu, Slack::Service.new(iu.slack_history_token, on_rate_limit: on_429)]
    end
  end
end
