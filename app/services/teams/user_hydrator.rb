# app/services/teams/user_hydrator.rb
#
# Purpose:
#   Incremental Microsoft Teams “structure hydration” for an EXISTING integration when a new user connects.
#
# Goals:
#   - Do NOT reset integration.setup_status/setup_progress/sync_status.
#   - Do NOT touch Channel history pointers (backfill_anchor_latest_ts/backfill_next_oldest_ts/forward_newest_ts/etc).
#   - Use the new user's delegated token to:
#       1) discover joined teams
#       2) upsert Team rows (if missing)
#       3) upsert Channel rows for those teams (if missing)
#       4) ensure ChannelMembership exists for THIS integration_user (the connecting user) for those channels
#       5) (optional) best-effort hydrate channel membership lists for newly discovered channels only
#          (kept conservative to avoid large workspace-wide resets)
#
# Non-goals:
#   - Full directory sync (users list) across tenant
#   - Full membership sync across all channels
#   - Message syncing (handled elsewhere)
#
# Notes:
#   - Reuses your existing IntegrationSetup helper patterns where possible.
#   - Uses integration.ensure_ms_access_token!(iu) so you do not duplicate token refresh logic.
#
module Teams
  class UserHydrator
    GRAPH_BASE = "https://graph.microsoft.com/v1.0".freeze
    PAGE_SIZE  = 50

    def initialize(integration:, iu:)
      @integration = integration
      @iu          = iu

      raise ArgumentError, "integration must be microsoft_teams" unless @integration.microsoft_teams?
      raise ArgumentError, "iu must belong to integration" unless @iu.integration_id == @integration.id
    end

    def run!
      token = @integration.ensure_ms_access_token!(@iu)
      unless token.present?
        Rails.logger.warn "[Teams::UserHydrator] no valid token iu=#{@iu.id} integration=#{@integration.id}"
        return false
      end

      # 1) Ensure the connecting user's profile exists/updated (best effort)
      hydrate_connecting_user_profile!(token)

      # 2) Discover teams + channels available to this user; upsert; ensure this user's memberships
      new_channel_ids = sync_joined_teams_and_channels_for_user!(token)

      # 3) Optional: hydrate member lists for newly discovered channels only
      #    (keeps this incremental and avoids expensive re-sync)
      hydrate_new_channel_memberships!(token, new_channel_ids) if new_channel_ids.any?

      true
    rescue => e
      Rails.logger.warn "[Teams::UserHydrator] failed integration=#{@integration.id} iu=#{@iu.id}: #{e.class}: #{e.message}"
      false
    end

    private

    # =====================================
    # 0) Connecting user profile (best effort)
    # =====================================

    def hydrate_connecting_user_profile!(token)
      url = "#{GRAPH_BASE}/me?$select=id,displayName,mail,userPrincipalName,jobTitle,accountEnabled"
      me  = http_get(url, token)
      return unless me.is_a?(Hash) && me["id"].present?

      upsert_integration_user_from_ms_user(me)
    rescue => e
      Rails.logger.warn "[Teams::UserHydrator] hydrate_connecting_user_profile failed iu=#{@iu.id}: #{e.class}: #{e.message}"
      nil
    end

    def upsert_integration_user_from_ms_user(ms_user)
      ms_id  = ms_user["id"]
      email  = ms_user["mail"].presence || ms_user["userPrincipalName"]
      name   = ms_user["displayName"].presence || email
      active = ms_user["accountEnabled"] != false
      title  = ms_user["jobTitle"]

      iu = @integration.integration_users.find_or_initialize_by(slack_user_id: ms_id)

      iu.display_name ||= name
      iu.real_name    ||= name
      iu.email        ||= email
      iu.title        ||= title
      iu.is_bot       = false if iu.has_attribute?(:is_bot)
      iu.active       = active if iu.has_attribute?(:active)

      # Preserve tokens already set for the connecting user row
      # (We do not overwrite ms_access_token/ms_refresh_token here.)

      iu.save! if iu.changed?
      iu
    end

    # =====================================
    # 1) Teams + channels visible to this user
    # =====================================

    def sync_joined_teams_and_channels_for_user!(token)
      new_channel_ids = []

      url = "#{GRAPH_BASE}/me/joinedTeams?$select=id,displayName,description"

      each_page(url, token) do |page|
        Array(page["value"]).each do |ms_team|
          team = upsert_team_from_ms_team(ms_team)

          # Channels for this team, visible to this user
          new_channel_ids.concat(sync_team_channels_for_user(team, token))
        end
      end

      new_channel_ids.uniq
    end

    def upsert_team_from_ms_team(ms_team)
      ms_team_id  = ms_team["id"]
      name        = ms_team["displayName"].presence || "Untitled Team"
      description = ms_team["description"]

      @integration.teams.find_or_initialize_by(ms_team_id: ms_team_id).tap do |team|
        team.name        = name
        team.description = description if team.respond_to?(:description=) && description.present?
        team.save!
      end
    end

    # Upserts channels WITHOUT touching any backfill pointers.
    # Ensures membership for the connecting user on each channel discovered.
    def sync_team_channels_for_user(team, token)
      url = "#{GRAPH_BASE}/teams/#{team.ms_team_id}/channels?$select=id,displayName,description,membershipType"
      new_ids = []

      each_page(url, token) do |page|
        Array(page["value"]).each do |ch|
          channel, created = upsert_channel_without_touching_history!(team, ch)
          ensure_membership_for_connecting_user!(channel) if channel
          new_ids << channel.id if created && channel
        end
      end

      new_ids
    rescue => e
      Rails.logger.warn "[Teams::UserHydrator] sync_team_channels_for_user failed team=#{team.id}: #{e.class}: #{e.message}"
      []
    end

    def upsert_channel_without_touching_history!(team, ch)
      ms_channel_id   = ch["id"].to_s
      return [nil, false] if ms_channel_id.blank?

      name            = ch["displayName"].presence || "Untitled channel"
      membership_type = ch["membershipType"].to_s # standard | private | shared

      is_private = (membership_type == "private")
      is_shared  = (membership_type == "shared")
      kind       = is_private ? "private_channel" : "public_channel"

      chan = @integration.channels.find_or_initialize_by(external_channel_id: ms_channel_id)
      created = chan.new_record?

      # Safe metadata only; DO NOT touch backfill_* / forward_newest_ts
      chan.name        = name if chan.name.blank?
      chan.kind        = kind
      chan.is_private  = is_private
      chan.is_shared   = is_shared
      chan.is_archived = false
      chan.team        = team if chan.respond_to?(:team=)

      chan.save!
      [chan, created]
    end

    def ensure_membership_for_connecting_user!(channel)
      ChannelMembership.find_or_create_by!(
        integration:      @integration,
        channel:          channel,
        integration_user: @iu
      )
    rescue ActiveRecord::RecordNotUnique
      true
    end

    # =====================================
    # 2) Optional: hydrate member lists for NEW channels only
    # =====================================

    def hydrate_new_channel_memberships!(token, channel_ids)
      return if channel_ids.blank?

      Channel.where(id: channel_ids).includes(:team).find_each do |channel|
        team = channel.team
        next unless team&.ms_team_id.present?

        sync_channel_members(team, channel, token)
      end
    end

    # Mirrors IntegrationSetup#sync_channel_members, but is used ONLY for newly discovered channels.
    def sync_channel_members(team, channel, token)
      url = "#{GRAPH_BASE}/teams/#{team.ms_team_id}/channels/#{channel.external_channel_id}/members"

      each_page(url, token) do |page|
        Array(page["value"]).each do |member|
          user_id = user_id_from_member(member)
          next if user_id.blank?

          iu = @integration.integration_users.find_by(slack_user_id: user_id)
          iu ||= hydrate_user_profile!(token, user_id)
          iu ||= @integration.integration_users.create!(
            slack_user_id: user_id,
            role:          "member",
            is_bot:        false,
            active:        true
          )

          ChannelMembership.find_or_create_by!(
            integration:      @integration,
            channel:          channel,
            integration_user: iu
          )
        end
      end
    rescue => e
      Rails.logger.warn "[Teams::UserHydrator] sync_channel_members failed channel=#{channel.id}: #{e.class}: #{e.message}"
    end

    # Pull user profile only when we only know an ID (same as IntegrationSetup)
    def hydrate_user_profile!(token, ms_user_id)
      url = "#{GRAPH_BASE}/users/#{ms_user_id}?$select=id,displayName,mail,userPrincipalName,jobTitle,accountEnabled"
      ms_user = http_get(url, token)
      return nil unless ms_user.is_a?(Hash) && ms_user["id"].present?

      upsert_integration_user_from_ms_user(ms_user)
      @integration.integration_users.find_by(slack_user_id: ms_user_id)
    rescue => e
      Rails.logger.warn "[Teams::UserHydrator] hydrate_user_profile failed for #{ms_user_id}: #{e.class}: #{e.message}"
      nil
    end

    def user_id_from_member(member)
      member["userId"].presence ||
        member.dig("user", "id").presence ||
        member.dig("user", "@odata.id").to_s.split("/").last.presence ||
        member.dig("@odata.id").to_s.split("/").last.presence
    end

    # =====================================
    # HTTP + paging helpers (copied from IntegrationSetup)
    # =====================================

    def each_page(url, token)
      loop do
        resp = http_get(url, token)
        break unless resp.is_a?(Hash) && resp["value"]

        yield resp

        next_link = resp["@odata.nextLink"]
        break if next_link.blank?
        url = next_link
      end
    end

    def http_get(url, token)
      conn = Faraday.new do |f|
        f.adapter Faraday.default_adapter
      end

      res = conn.get(url) do |req|
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["Accept"]        = "application/json"
      end

      body =
        begin
          JSON.parse(res.body)
        rescue
          nil
        end

      if res.status.between?(200, 299)
        body || {}
      else
        Rails.logger.warn "[Teams::UserHydrator] GET #{url} failed: #{res.status}"
        nil
      end
    end
  end
end
