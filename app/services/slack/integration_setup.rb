# Purpose:
#   Slack “directory + structure” sync for an integration.
#   Imports Slack users into integration_users, discovers channels, and builds channel membership rows.
#   This is the setup data used by onboarding (people + channels); message history syncing is handled separately.
module Slack
  class IntegrationSetup
    PAGE = 200

    def initialize(integration)
      @integration = integration
    end

    def run!
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rails.logger.info("[AnalyzerFlow][SlackSetup] stage=start integration_id=#{@integration.id}")

      sync_members!
      Rails.logger.info("[AnalyzerFlow][SlackSetup] stage=members_done integration_id=#{@integration.id} users=#{@integration.integration_users.count}")

      sync_channels_and_memberships!
      Rails.logger.info("[AnalyzerFlow][SlackSetup] stage=channels_memberships_done integration_id=#{@integration.id} channels=#{@integration.channels.count} memberships=#{ChannelMembership.where(integration_id: @integration.id).count}")

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
      Rails.logger.info("[AnalyzerFlow][SlackSetup] stage=done integration_id=#{@integration.id} elapsed_ms=#{elapsed_ms}")
    end

    private

    def installer_iuser
      @integration.integration_users
                  .where.not(slack_history_token: nil)
                  .order(:id)
                  .first || raise("No Slack user token available for integration #{@integration.id}")
    end

    def client(token = installer_iuser.slack_history_token)
      Slack::Service.new(token)
    end

    # -----------------------
    # Bot detection helpers
    # -----------------------

    def bot_like_slack_id?(slack_user_id)
      sid = slack_user_id.to_s
      return true if sid.start_with?("bot:")
      return true if sid == "USLACKBOT"
      # Some APIs surface bot ids starting with "B" (bot_id), not user ids.
      # If you ever persist them into slack_user_id, treat them as bots.
      return true if sid.match?(/\A[BW][A-Z0-9]+\z/) # conservative; remove W if you dislike it
      false
    end

    def slack_member_is_bot?(m)
      # m is a Slack::Messages::Message (or hash-like)
      p = m.respond_to?(:profile) ? m.profile : nil

      is_bot_flag =
        (m.respond_to?(:is_bot) && m.is_bot) ||
        (m.respond_to?(:bot_id) && m.bot_id.present?) ||
        (m.respond_to?(:app_id) && m.app_id.present?) ||
        (m[:is_bot] rescue nil) || (m["is_bot"] rescue nil)

      id = (m.respond_to?(:id) ? m.id : (m[:id] rescue nil) || (m["id"] rescue nil))
      name = (m.respond_to?(:name) ? m.name : (m[:name] rescue nil) || (m["name"] rescue nil))

      is_slackbot = (id.to_s == "USLACKBOT") || (name.to_s.downcase == "slackbot")
      has_profile_bot_id = p&.respond_to?(:bot_id) && p.bot_id.present?

      !!(is_bot_flag || is_slackbot || has_profile_bot_id || bot_like_slack_id?(id))
    end

    # Upsert Slack directory into integration_users (user_id can remain nil)
    def sync_members!
      cursor = nil
      loop do
        resp = client.users_list(limit: PAGE, cursor: cursor)
        (resp.members || []).each do |m|
          upsert_integration_user!(m)
        end
        cursor = resp.response_metadata&.next_cursor
        break if cursor.blank?
      end
    end

    def upsert_integration_user!(m)
      slack_uid = m.respond_to?(:id) ? m.id : (m[:id] || m["id"])
      iu = @integration.integration_users.find_or_initialize_by(slack_user_id: slack_uid)

      p = m.respond_to?(:profile) ? m.profile : nil

      iu.display_name ||= p&.display_name
      iu.real_name    ||= p&.real_name
      iu.email        ||= p&.email
      iu.avatar_url   ||= p&.image_512 || p&.image_192
      iu.title        ||= p&.title

      if iu.has_attribute?(:is_bot)
        iu.is_bot = slack_member_is_bot?(m) || bot_like_slack_id?(iu.slack_user_id)
      end

      if iu.has_attribute?(:active)
        is_deleted = (m.respond_to?(:deleted) ? m.deleted : (m[:deleted] || m["deleted"]))
        iu.active  = !is_deleted
      end

      iu.save!
    end

    # Discover channels with a single canonical token (installer), create channels, add membership for that token owner,
    # and (when allowed) fetch full member list per channel.
    def sync_channels_and_memberships!
      tokens = @integration.integration_users.where.not(slack_history_token: nil).order(:id).to_a
      raise("No Slack user token available for integration #{@integration.id}") if tokens.empty?

      # Avoid duplicating IMs seen via different user tokens by keying on participant pairs.
      im_key_to_channel = {}
      channel_hydration_state = {} # channel_id => :done or :failed

      tokens.each do |iu|
        client = Slack::Service.new(iu.slack_history_token)
        cursor = nil

        loop do
          resp = client.users_conversations(
            types:  "public_channel,private_channel,mpim,im",
            limit:  PAGE,
            cursor: cursor
          )

          (resp.channels || []).each do |raw|
            channel, slack_id = find_or_attach_channel!(raw, token_owner: iu, cache: im_key_to_channel)
            ensure_membership!(channel, iu)

            # Hydrate full membership once per channel (best effort; retry across tokens if a scope/channel issue occurs)
            hydrated_state = channel_hydration_state[channel.id]
            next if hydrated_state == :done

            hydrated = hydrate_members!(channel, client, slack_channel_id: slack_id)
            channel_hydration_state[channel.id] = hydrated ? :done : :failed
          end

          cursor = resp.response_metadata&.next_cursor
          break if cursor.blank?
        end
      end
    end

    def find_or_attach_channel!(raw, token_owner:, cache:)
      slack_id = raw.respond_to?(:id) ? raw.id : (raw[:id] rescue nil) || raw["id"]

      identity = ChannelIdentity.find_by(
        integration_id:      @integration.id,
        provider:            "slack",
        external_channel_id: slack_id
      )

      if identity
        identity.update!(
          integration_user_id: identity.integration_user_id || token_owner.id,
          last_seen_at:        Time.current
        )
        return [identity.channel, slack_id]
      end

      channel = if raw["is_im"]
                  ensure_im_channel(raw, token_owner: token_owner, cache: cache)
                else
                  upsert_channel_by_name!(raw)
                end

      ChannelIdentity.find_or_create_by!(
        integration:         @integration,
        channel:             channel,
        integration_user:    token_owner,
        provider:            "slack",
        external_channel_id: slack_id
      ) do |ci|
        ci.discovered_at = Time.current
        ci.last_seen_at  = Time.current
      end

      [channel, slack_id]
    end

    def ensure_im_channel(raw, token_owner:, cache:)
      other_id = raw["user"].to_s.presence
      owner_id = token_owner.slack_user_id.to_s.presence
      key = [owner_id, other_id].compact.sort.join(":")

      if key.present?
        cached = cache[key]
        return cached if cached
        existing = find_im_channel_by_participants(owner_id, other_id)
        cache[key] = existing if existing
        return existing if existing
      end

      ch = upsert_channel_by_name!(raw)
      cache[key] = ch if key.present?
      ch
    end

    def find_im_channel_by_participants(a, b)
      return nil if a.blank? || b.blank?

      @integration.channels
                  .where(kind: "im")
                  .joins(channel_memberships: :integration_user)
                  .where(integration_users: { slack_user_id: [a, b] })
                  .group("channels.id")
                  .having("COUNT(DISTINCT integration_users.slack_user_id) = 2")
                  .first
    end

    def upsert_channel_by_name!(c)
      kind =
        if c["is_im"]    then "im"
        elsif c["is_mpim"] then "mpim"
        elsif c["is_private"] then "private_channel"
        else "public_channel"
        end

      slack_id = c.respond_to?(:id) ? c.id : c["id"]
      name = (c["name"] || c["user"]).to_s

      channel_scope = @integration.channels
      channel_scope = channel_scope.where("LOWER(name) = ?", name.downcase) if name.present?

      ch = channel_scope.first || @integration.channels.new
      ch.external_channel_id ||= slack_id
      ch.kind         = kind
      ch.name       ||= (c["name"] || c["user"])
      ch.is_archived  = !!c["is_archived"]
      ch.is_shared    = !!c["is_shared"]
      ch.created_unix ||= c["created"]
      ch.save!
      ch
    end

    def ensure_membership!(channel, iu)
      ChannelMembership.find_or_create_by!(
        integration:      @integration,
        channel:          channel,
        integration_user: iu
      )
    end

    def hydrate_members!(channel, c, slack_channel_id:)
      return false if slack_channel_id.blank?

      cursor = nil
      loop do
        resp = c.conversations_members(channel: slack_channel_id, limit: PAGE, cursor: cursor)

        (resp.members || []).each do |slack_uid|
          slack_uid = slack_uid.to_s

          iu = @integration.integration_users.find_or_create_by!(slack_user_id: slack_uid)

          # ✅ Critical: classify bot-like IDs even if we only have an ID
          if iu.has_attribute?(:is_bot) && iu.is_bot == false && bot_like_slack_id?(slack_uid)
            iu.update!(is_bot: true)
          end

          ChannelMembership.find_or_create_by!(
            integration:      @integration,
            channel:          channel,
            integration_user: iu
          )
        end

        cursor = resp.response_metadata&.next_cursor
        break if cursor.blank?
      end

      true
    rescue Slack::Web::Api::Errors::MissingScope, Slack::Web::Api::Errors::NotInChannel
      # Not fatal; we still have at least the installing user's membership.
      false
    end
  end
end
