# integration_setup.rb
# Bootstraps a Microsoft Teams integration after OAuth: pulls directory users, joined teams, team channels,
# and team/channel memberships so onboarding can immediately list people and channels (messages are handled separately).

module Teams
  class IntegrationSetup
    GRAPH_BASE = "https://graph.microsoft.com/v1.0".freeze

    def self.call(integration)
      new(integration).call
    end

    def initialize(integration)
      @integration = integration
    end

    def call
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      unless @integration.microsoft_teams?
        Rails.logger.info "[Teams::IntegrationSetup] integration #{@integration.id} is kind=#{@integration.kind}, skipping"
        return
      end

      Rails.logger.info "[AnalyzerFlow][TeamsSetup] stage=start integration_id=#{@integration.id}"

      tokens = integration_tokens
      if tokens.empty?
        Rails.logger.warn "[Teams::IntegrationSetup] no valid Teams token for integration #{@integration.id}"
        Rails.logger.warn "[AnalyzerFlow][TeamsSetup] stage=no_tokens integration_id=#{@integration.id}"
        return
      end

      sync_all_users(tokens.first[:token])
      Rails.logger.info "[AnalyzerFlow][TeamsSetup] stage=users_done integration_id=#{@integration.id} users=#{@integration.integration_users.count}"

      sync_teams_and_memberships(tokens)
      Rails.logger.info "[AnalyzerFlow][TeamsSetup] stage=channels_memberships_done integration_id=#{@integration.id} channels=#{@integration.channels.count} memberships=#{ChannelMembership.where(integration_id: @integration.id).count}"

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
      Rails.logger.info "[AnalyzerFlow][TeamsSetup] stage=done integration_id=#{@integration.id} elapsed_ms=#{elapsed_ms}"
      Rails.logger.info "[Teams::IntegrationSetup] setup complete for integration #{@integration.id}"
    rescue => e
      Rails.logger.error "[AnalyzerFlow][TeamsSetup] stage=failed integration_id=#{@integration.id} error_class=#{e.class} error=#{e.message}"
      Rails.logger.error "[Teams::IntegrationSetup] setup failed for integration #{@integration.id}: #{e.class}: #{e.message}"
    end

    private

    def installer_iuser
      @integration.installer_integration_user ||
        raise("No Teams user token available for integration #{@integration.id}")
    end

    # Return an array of token payloads for every connected user with a valid refresh token.
    def integration_tokens
      @integration.integration_users
                  .where.not(ms_refresh_token: nil)
                  .order(:id)
                  .filter_map do |iu|
        token = @integration.ensure_ms_access_token!(iu)
        { integration_user: iu, token: token } if token.present?
      end
    end

    # =====================================
    # USERS (directory)
    # =====================================

    def sync_all_users(token)
      url = "#{GRAPH_BASE}/users?$select=id,displayName,mail,userPrincipalName,jobTitle,accountEnabled"

      each_page(url, token) do |page|
        Array(page["value"]).each do |ms_user|
          upsert_integration_user_from_ms_user(ms_user)
        end
      end
    end

    def upsert_integration_user_from_ms_user(ms_user)
      ms_id   = ms_user["id"]
      email   = ms_user["mail"].presence || ms_user["userPrincipalName"]
      name    = ms_user["displayName"].presence || email
      active  = ms_user["accountEnabled"] != false
      title   = ms_user["jobTitle"]

      iu = @integration.integration_users.find_or_initialize_by(slack_user_id: ms_id)
      iu.display_name = name if iu.display_name.blank?
      iu.real_name    = name if iu.real_name.blank?
      iu.email        = email if iu.email.blank?
      iu.title        = title if iu.title.blank?
      iu.is_bot       = false if iu.has_attribute?(:is_bot)
      iu.active       = active if iu.has_attribute?(:active)
      iu.save!
    end

    # Fill in "Unknown" users when we only know a user ID from membership/chats.
    def hydrate_user_profile!(token, ms_user_id)
      url = "#{GRAPH_BASE}/users/#{ms_user_id}?$select=id,displayName,mail,userPrincipalName,jobTitle,accountEnabled"
      ms_user = http_get(url, token)
      return nil unless ms_user.is_a?(Hash) && ms_user["id"].present?

      upsert_integration_user_from_ms_user(ms_user)
      @integration.integration_users.find_by(slack_user_id: ms_user_id)
    rescue => e
      Rails.logger.warn "[Teams::IntegrationSetup] hydrate_user_profile failed for #{ms_user_id}: #{e.class}: #{e.message}"
      nil
    end

    # =====================================
    # TEAMS + MEMBERSHIPS + CHANNELS
    # =====================================

    def sync_teams_and_memberships(tokens)
      team_hydration_state    = {} # team.id => :done or :failed
      channel_hydration_state = {} # channel.id => :done or :failed

      tokens.each do |token_entry|
        token = token_entry[:token]
        next if token.blank?

        url = "#{GRAPH_BASE}/me/joinedTeams?$select=id,displayName,description"

        each_page(url, token) do |page|
          Array(page["value"]).each do |ms_team|
            team = upsert_team_from_ms_team(ms_team)

            if team_hydration_state[team.id] != :done
              hydrated_team = sync_team_members(team, token)
              team_hydration_state[team.id] = hydrated_team ? :done : :failed
            end

            channels = sync_team_channels(team, token)
            channels.each do |channel|
              status = channel_hydration_state[channel.id]
              next if status == :done

              hydrated_channel = sync_channel_members(team, channel, token)
              channel_hydration_state[channel.id] = hydrated_channel ? :done : :failed
            end
          end
        end
      end
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

    def sync_team_channels(team, token)
      url = "#{GRAPH_BASE}/teams/#{team.ms_team_id}/channels?$select=id,displayName,description,membershipType"
      out = []

      each_page(url, token) do |page|
        Array(page["value"]).each do |ch|
          ms_channel_id   = ch["id"]
          name            = ch["displayName"].presence || "Untitled channel"
          membership_type = ch["membershipType"].to_s # standard | private | shared

          is_private = (membership_type == "private")
          is_shared  = (membership_type == "shared")

          kind = is_private ? "private_channel" : "public_channel"

          channel = @integration.channels.find_or_initialize_by(external_channel_id: ms_channel_id).tap do |chan|
            chan.name        = name
            chan.kind        = kind
            chan.is_private  = is_private
            chan.is_shared   = is_shared
            chan.is_archived = false
            chan.team        = team if chan.respond_to?(:team=)
            chan.save!
          end

          out << channel
        end
      end

      out
    rescue => e
      Rails.logger.warn "[Teams::IntegrationSetup] sync_team_channels failed for team=#{team.id}: #{e.class}: #{e.message}"
      []
    end

    def sync_team_members(team, token)
      # IMPORTANT: do NOT add $select=userId; Graph will 400 for conversationMember
      url = "#{GRAPH_BASE}/teams/#{team.ms_team_id}/members"

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

          TeamMembership.find_or_create_by!(team: team, integration_user: iu)
        end
      end
    rescue => e
      Rails.logger.warn "[Teams::IntegrationSetup] sync_team_members failed for team=#{team.id}: #{e.class}: #{e.message}"
      false
    else
      true
    end

    def sync_channel_members(team, channel, token)
      # IMPORTANT: do NOT add $select=userId; Graph will 400 for conversationMember
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
      Rails.logger.warn "[Teams::IntegrationSetup] sync_channel_members failed for channel=#{channel.id}: #{e.class}: #{e.message}"
      false
    else
      true
    end

    def user_id_from_member(member)
      member["userId"].presence ||
        member.dig("user", "id").presence ||
        member.dig("user", "@odata.id").to_s.split("/").last.presence ||
        member.dig("@odata.id").to_s.split("/").last.presence
    end

    # =====================================
    # HTTP + paging helpers
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
        Rails.logger.warn "[Teams::IntegrationSetup] GET #{url} failed: #{res.status}" #INSECURE #{res.body}"
        nil
      end
    end
  end
end
