# slack_service.rb
# Small wrapper around Slack Web API operations (auth, pagination, retries, rate-limit handling) used by
# Slack ingestion and audit jobs to keep API access consistent and centralized.
require 'slack-ruby-client'

module Slack
  class Service
    # @param token [String] any valid Slack token (xoxb, xoxp or user token)
    def initialize(token, on_rate_limit: nil)
      @client = Slack::Web::Client.new(token: token)
      @on_rate_limit = on_rate_limit
    end

    # === OAuth ===
    # Exchange a code for bot & user tokens
    # @see https://api.slack.com/methods/oauth.v2.access
    def oauth_v2_access(client_id:, client_secret:, code:, redirect_uri:)
      with_rate_limit do
        @client.oauth_v2_access(
          client_id:     client_id,
          client_secret: client_secret,
          code:          code,
          redirect_uri:  redirect_uri
        )
      end
    end

    # === Workspace Info ===
    # @see https://api.slack.com/methods/team.info
    def team_info
      with_rate_limit { @client.team_info }
    end

    # === Conversations ===
    # @see https://api.slack.com/methods/conversations.list
    def conversations_list(types:, limit:, cursor: nil)
      with_rate_limit { @client.conversations_list(types: types, limit: limit, cursor: cursor) }
    end

    # @see https://api.slack.com/methods/conversations.history
    # now accepts `oldest`, `latest`, etc.
    def conversations_history(channel:, limit:, cursor: nil, **extra)
      with_rate_limit do
        @client.conversations_history(
          channel: channel,
          limit:   limit,
          cursor:  cursor,
          **extra
        )
      end
    end

    # @see https://api.slack.com/methods/conversations.open
    def conversations_open(users:)
      with_rate_limit { @client.conversations_open(users: users) }
    end

    # === Users ===
    # @see https://api.slack.com/methods/users.list
    def users_list(limit:, cursor: nil)
      with_rate_limit { @client.users_list(limit: limit, cursor: cursor) }
    end

    # @see https://api.slack.com/methods/users.info
    def users_info(user:)
      with_rate_limit { @client.users_info(user: user) }
    end

    # === Chat ===
    # @see https://api.slack.com/methods/chat.postMessage
    def chat_postMessage(channel:, text:, **opts)
      with_rate_limit { @client.chat_postMessage(channel: channel, text: text, **opts) }
    end

    # === Fallback for any other endpoint ===
    def method_missing(name, *args, **kwargs, &block)
      if @client.respond_to?(name)
        with_rate_limit { @client.public_send(name, *args, **kwargs, &block) }
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @client.respond_to?(name) || super
    end

    private

    # Handle Slack rate limits by retrying after the specified delay
    def with_rate_limit
      yield
    rescue Slack::Web::Api::Errors::TooManyRequestsError => e
      retry_after = e.retry_after.to_i.nonzero? || 1
      @on_rate_limit&.call(retry_after)
      sleep retry_after
      retry
    end
  end
end
