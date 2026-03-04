# app/services/slack/user_hydrator.rb
#
# Purpose:
#   Incremental Slack "directory + structure" hydration for an EXISTING integration
#   when a new user connects (adds a new user token).
#
# Goals:
#   - Do NOT touch channel history pointers/backfill anchors (those live on Channel and must remain stable).
#   - Do NOT reset integration setup fields or sync_status.
#   - Use the new token to:
#       1) discover channels visible to this user and upsert any missing Channel rows
#       2) ensure ChannelMembership exists for this IntegrationUser in those channels
#       3) (best effort) hydrate full member lists for newly discovered channels only
#   - Ensure IntegrationUser profile for the connecting user is upserted (nice-to-have).
#
# Non-goals:
#   - Message ingestion / backfill (handled by your cron/jobs already via Slack::HistoryIngestor)
#
module Slack
  class UserHydrator
    PAGE = 200

    def initialize(integration:, iu:)
      @integration = integration
      @iu          = iu
      raise ArgumentError, "integration must be Slack" unless @integration.kind.to_s == "slack"
      raise ArgumentError, "iu must belong to integration" unless @iu.integration_id == @integration.id
      raise ArgumentError, "missing slack_history_token" if @iu.slack_history_token.blank?
    end

    def run!
      # 1) Ensure we have a sane IntegrationUser row for the connecting user
      sync_connecting_user_profile!

      # 2) Discover channels visible to this user and upsert any new ones
      newly_created = discover_channels_and_memberships!

      # 3) Best-effort: hydrate full membership for newly discovered channels only
      #    (Do NOT re-hydrate everything; that's the "reset/overkill" behavior)
      hydrate_members_for_new_channels!(newly_created) if newly_created.any?

      true
    end

    private

    def client
      @client ||= Slack::Service.new(@iu.slack_history_token)
    end

    # -----------------------
    # Bot detection helpers
    # (same logic as IntegrationSetup)
    # -----------------------
    def bot_like_slack_id?(slack_user_id)
      sid = slack_user_id.to_s
      return true if sid.start_with?("bot:")
      return true if sid == "USLACKBOT"
      return true if sid.match?(/\A[BW][A-Z0-9]+\z/)
      false
    end

    # -----------------------
    # 1) Connect user profile
    # -----------------------
    def sync_connecting_user_profile!
      # Best effort: some Slack installs may not have scope; do not fail hydration
      slack_uid = @iu.slack_user_id.to_s
      return if slack_uid.blank?

      begin
        resp = client.users_info(user: slack_uid)
        user = resp&.user
        return unless user

        profile = user.respond_to?(:profile) ? user.profile : nil

        @iu.display_name ||= profile&.display_name
        @iu.real_name    ||= profile&.real_name
        @iu.email        ||= profile&.email
        @iu.avatar_url   ||= profile&.image_512 || profile&.image_192
        @iu.title        ||= profile&.title

        if @iu.has_attribute?(:is_bot)
          # connecting user should be human; but keep consistent with your bot-like heuristics
          @iu.is_bot = bot_like_slack_id?(slack_uid) if @iu.is_bot.nil?
        end

        if @iu.has_attribute?(:active)
          is_deleted = user.respond_to?(:deleted) ? user.deleted : (user[:deleted] rescue nil)
          @iu.active = !is_deleted if !is_deleted.nil?
        end

        @iu.save! if @iu.changed?
      rescue Slack::Web::Api::Errors::MissingScope
        # ignore
      rescue => e
        Rails.logger.warn("[Slack::UserHydrator] users_info failed iu=#{@iu.id}: #{e.class}: #{e.message}")
      end
    end

    # -----------------------
    # 2) Channel discovery + membership for this IU
    # -----------------------
    def discover_channels_and_memberships!
      newly_created = {}

      cursor = nil
      loop do
        resp = client.users_conversations(
          types:  "public_channel,private_channel,mpim,im",
          limit:  PAGE,
          cursor: cursor
        )

        (resp.channels || []).each do |raw|
          ch, slack_id, created = find_or_attach_channel!(raw)
          ensure_membership!(ch, @iu)

          newly_created[ch.id] ||= slack_id if created
        end

        cursor = resp.response_metadata&.next_cursor
        break if cursor.blank?
      end

      newly_created
    end

    # Critical: this must NOT modify backfill_* pointers that history ingestors rely on.
    # It only sets basic channel fields if missing.
    def upsert_channel_without_touching_history!(c)
      kind =
        if c["is_im"] then "im"
        elsif c["is_mpim"] then "mpim"
        elsif c["is_private"] then "private_channel"
        else "public_channel"
        end

      slack_id = c.respond_to?(:id) ? c.id : c["id"]
      name = (c["name"] || c["user"]).to_s
      channel_scope = @integration.channels
      channel_scope = channel_scope.where("LOWER(name) = ?", name.downcase) if name.present?

      ch = channel_scope.first || @integration.channels.new
      created = ch.new_record?

      ch.kind = kind

      # Only fill name if blank; do not overwrite existing names
      ch.name ||= (c["name"] || c["user"])

      # These are safe to keep in sync (do not touch backfill pointers)
      ch.is_archived = !!c["is_archived"] if ch.has_attribute?(:is_archived)
      ch.is_shared   = !!c["is_shared"]   if ch.has_attribute?(:is_shared)

      # Only set created_unix if missing
      ch.created_unix ||= c["created"]
      ch.external_channel_id ||= slack_id

      ch.save!
      [ch, created]
    end

    def find_or_attach_channel!(raw)
      slack_id = raw.respond_to?(:id) ? raw.id : (raw[:id] rescue nil) || raw["id"]

      identity = ChannelIdentity.find_by(
        integration_id:      @integration.id,
        provider:            "slack",
        external_channel_id: slack_id
      )

      if identity
        identity.update!(
          integration_user_id: identity.integration_user_id || @iu.id,
          last_seen_at:        Time.current
        )
        return [identity.channel, slack_id, false]
      end

      ch, created = upsert_channel_without_touching_history!(raw)

      ChannelIdentity.find_or_create_by!(
        integration:         @integration,
        channel:             ch,
        integration_user:    @iu,
        provider:            "slack",
        external_channel_id: slack_id
      ) do |ci|
        ci.discovered_at = Time.current
        ci.last_seen_at  = Time.current
      end

      [ch, slack_id, created]
    end

    def ensure_membership!(channel, iu)
      ChannelMembership.find_or_create_by!(
        integration:      @integration,
        channel:          channel,
        integration_user: iu
      )
    rescue ActiveRecord::RecordNotUnique
      # safe in concurrent hydrations
      true
    end

    # -----------------------
    # 3) Optional: hydrate full membership for NEW channels only
    # -----------------------
    def hydrate_members_for_new_channels!(channel_id_map)
      Channel.where(id: channel_id_map.keys).find_each do |channel|
        hydrate_members_for_channel!(channel, slack_channel_id: channel_id_map[channel.id])
      end
    end

    def hydrate_members_for_channel!(channel, slack_channel_id: nil)
      slack_channel_id ||= channel.slack_external_id_for(integration_user: @iu)
      return true if slack_channel_id.blank?

      cursor = nil
      loop do
        resp = client.conversations_members(
          channel: slack_channel_id,
          limit:   PAGE,
          cursor:  cursor
        )

        (resp.members || []).each do |slack_uid|
          slack_uid = slack_uid.to_s
          next if slack_uid.blank?

          iu = @integration.integration_users.find_or_create_by!(slack_user_id: slack_uid)

          # Mark bot-like ids as bots even if we only have an ID
          if iu.has_attribute?(:is_bot) && iu.is_bot == false && bot_like_slack_id?(slack_uid)
            iu.update!(is_bot: true)
          end

          ensure_membership!(channel, iu)
        end

        cursor = resp.response_metadata&.next_cursor
        break if cursor.blank?
      end
    rescue Slack::Web::Api::Errors::MissingScope, Slack::Web::Api::Errors::NotInChannel
      # Not fatal.
      # If we can't list members, we still ensured membership for the connecting user.
      true
    rescue => e
      Rails.logger.warn("[Slack::UserHydrator] conversations_members failed channel=#{channel.id}: #{e.class}: #{e.message}")
      true
    end
  end
end
