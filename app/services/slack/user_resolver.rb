# Purpose:
#   Ensures an IntegrationUser record exists for any Slack message payload and hydrates
#   whatever profile fields are present on the message payload itself.
#   This avoids per-message users.info lookups during backfill.

module Slack
  class UserResolver
    def initialize(integration)
      @integration = integration
    end

    # Returns an IntegrationUser (ensuring it exists) for any Slack message payload.
    def resolve!(msg, fallback_name: "Slack System")
      slack_uid = msg["user"] ||
                  msg.dig("bot_profile", "user_id") ||
                  (msg["bot_id"] && "bot:#{msg['bot_id']}") ||
                  "system"

      iu = @integration.integration_users.find_or_initialize_by(slack_user_id: slack_uid)

      # Fill from payload if present
      prof = msg["user_profile"] || msg["bot_profile"] || {}

      iu.display_name ||= prof["display_name"]
      iu.real_name    ||= prof["real_name"] || prof["name"]
      iu.avatar_url   ||= prof["image_512"] || prof["image_192"]
      iu.email        ||= prof["email"]

      if slack_uid == "system"
        iu.display_name ||= fallback_name
        iu.real_name    ||= fallback_name
      end

      iu.save! if iu.changed?
      iu
    end
  end
end
