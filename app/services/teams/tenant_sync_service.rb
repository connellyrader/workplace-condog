# app/services/teams/tenant_sync_service.rb
# Tenant-level sync that fetches messages once per Teams tenant
# and distributes to all integrations sharing that tenant

module Teams
  class TenantSyncService
    GRAPH_BASE = "https://graph.microsoft.com/v1.0".freeze
    
    def self.sync_all_tenants!
      # Find all unique Teams tenants with multiple integrations
      tenants = Integration.joins(:workspace)
                          .where(kind: "microsoft_teams")
                          .where(workspaces: { archived_at: nil })
                          .where.not(ms_tenant_id: nil)
                          .group(:ms_tenant_id)
                          .having("COUNT(*) >= 1") # Include single integrations too
                          .pluck(:ms_tenant_id)
      
      Rails.logger.info "[Teams::TenantSyncService] Found #{tenants.count} Teams tenants to sync"
      
      tenants.each do |tenant_id|
        begin
          sync_tenant!(tenant_id)
        rescue => e
          Rails.logger.error "[Teams::TenantSyncService] Failed to sync tenant #{tenant_id}: #{e.message}"
        end
      end
    end
    
    def self.sync_tenant!(tenant_id)
      new(tenant_id).sync!
    end
    
    def initialize(tenant_id)
      @tenant_id = tenant_id
      @integrations = Integration
        .joins(:workspace)
        .where(ms_tenant_id: tenant_id, kind: "microsoft_teams")
        .where(workspaces: { archived_at: nil })
    end
    
    def sync!
      Rails.logger.info "[Teams::TenantSyncService] Syncing tenant #{@tenant_id} for #{@integrations.count} integrations"
      
      # Get any available token from any integration
      token = find_available_token
      unless token
        Rails.logger.warn "[Teams::TenantSyncService] No available token for tenant #{@tenant_id}"
        return
      end
      
      # Get unique external channels across all integrations
      unique_channels = get_unique_external_channels
      Rails.logger.info "[Teams::TenantSyncService] Found #{unique_channels.count} unique channels for tenant #{@tenant_id}"
      
      # Sync each unique external channel once
      unique_channels.each do |external_channel_data|
        sync_external_channel_for_all_integrations(external_channel_data, token)
      end
    end
    
    private
    
    def find_available_token
      # Find the first available token across all integrations for this tenant
      @integrations.each do |integration|
        available_user = integration.integration_users
                                   .where.not(ms_refresh_token: nil)
                                   .where("rate_limited_until IS NULL OR rate_limited_until < ?", Time.current)
                                   .first
        
        if available_user
          begin
            return integration.ensure_ms_access_token!(available_user)
          rescue => e
            Rails.logger.warn "[Teams::TenantSyncService] Token failed for integration #{integration.id}: #{e.message}"
            next
          end
        end
      end
      
      nil
    end
    
    def get_unique_external_channels
      # Get all distinct external channel IDs across all integrations
      channels = Channel.joins(integration: :workspace)
                       .where(integrations: { ms_tenant_id: @tenant_id, kind: "microsoft_teams" })
                       .where(workspaces: { archived_at: nil })
                       .where(kind: %w[public_channel private_channel im mpim])
                       .where.not(external_channel_id: nil)
                       .where(is_archived: false)
      
      # Group by external_channel_id to avoid duplicates
      channels.group(:external_channel_id, :kind).select(
        :external_channel_id,
        :kind,
        "MIN(channels.id) as sample_channel_id",
        "COUNT(*) as integration_count"
      ).map do |grouped|
        {
          external_channel_id: grouped.external_channel_id,
          kind: grouped.kind,
          sample_channel: Channel.find(grouped.sample_channel_id),
          integration_count: grouped.integration_count
        }
      end
    end
    
    def sync_external_channel_for_all_integrations(external_channel_data, token)
      external_id = external_channel_data[:external_channel_id]
      channel_kind = external_channel_data[:kind]
      sample_channel = external_channel_data[:sample_channel]
      
      Rails.logger.info "[Teams::TenantSyncService] Syncing #{external_id} (#{channel_kind}) for #{external_channel_data[:integration_count]} integrations"
      
      # Get messages for this external channel (single API call)
      messages = fetch_messages_for_external_channel(sample_channel, token)
      
      if messages.any?
        # Distribute to all integrations that have this external channel
        distribute_messages_to_integrations(external_id, messages)
      end
      
    rescue => e
      if e.message.include?("429")
        handle_rate_limit(e, token)
      else
        Rails.logger.error "[Teams::TenantSyncService] Error syncing channel #{external_id}: #{e.message}"
      end
    end
    
    def fetch_messages_for_external_channel(sample_channel, token)
      # Use the sample channel to determine API endpoint
      if sample_channel.kind.in?(['im', 'mpim'])
        url = "#{GRAPH_BASE}/chats/#{sample_channel.external_channel_id}/messages"
      else
        url = "#{GRAPH_BASE}/teams/#{sample_channel.team.ms_team_id}/channels/#{sample_channel.external_channel_id}/messages"
      end
      
      # Get messages since last sync (use the most recent forward_newest_ts)
      last_sync_ts = Channel.where(external_channel_id: sample_channel.external_channel_id)
                           .maximum(:forward_newest_ts) || 0
      
      messages = []
      
      # Simple pagination handling with rate limit retry
      each_page_with_retry(url, token) do |page|
        Array(page["value"]).each do |msg|
          created_at = parse_time(msg["createdDateTime"])
          next unless created_at
          
          # Only get messages newer than our last sync
          if created_at.to_f > last_sync_ts
            messages << msg
          end
        end
        
        # Stop if we found old messages (no need to paginate further)
        break if messages.any? && messages.last && parse_time(messages.last["createdDateTime"])&.to_f <= last_sync_ts
      end
      
      messages
    end
    
    def distribute_messages_to_integrations(external_channel_id, messages)
      # Find all channels across all integrations with this external ID
      target_channels = Channel.joins(integration: :workspace)
                              .where(integrations: { ms_tenant_id: @tenant_id })
                              .where(workspaces: { archived_at: nil })
                              .where(external_channel_id: external_channel_id)
      
      Rails.logger.info "[Teams::TenantSyncService] Distributing #{messages.count} messages to #{target_channels.count} channels"
      
      target_channels.each do |channel|
        integration = channel.integration
        sync_service = Teams::HistorySyncService.new(integration)
        
        # Store each message for this integration/channel
        messages.each do |msg|
          begin
            sync_service.send(:upsert_message_from_ms, msg, channel)
          rescue => e
            Rails.logger.warn "[Teams::TenantSyncService] Failed to store message for integration #{integration.id}: #{e.message}"
          end
        end
        
        # Update channel forward timestamp
        if messages.any?
          newest_ts = messages.map { |m| parse_time(m["createdDateTime"])&.to_f }.compact.max
          if newest_ts
            current_newest = channel.forward_newest_ts || 0
            channel.update_columns(
              forward_newest_ts: [current_newest, newest_ts].max,
              last_audit_at: Time.current
            )
          end
        end
      end
    end
    
    def each_page_with_retry(url, token, max_retries: 3)
      retries = 0
      
      loop do
        begin
          response = http_get_with_retry(url, token)
          break unless response && response["value"]
          
          yield response
          
          next_link = response["@odata.nextLink"]
          break if next_link.blank?
          url = next_link
          
        rescue => e
          if e.message.include?("429") && retries < max_retries
            retries += 1
            retry_after = extract_retry_after(e) || 60
            Rails.logger.warn "[Teams::TenantSyncService] Rate limited, waiting #{retry_after}s (attempt #{retries})"
            sleep(retry_after)
            retry
          else
            raise e
          end
        end
      end
    end
    
    def handle_rate_limit(error, token)
      retry_after = extract_retry_after(error) || 60
      Rails.logger.warn "[Teams::TenantSyncService] Tenant #{@tenant_id} rate limited for #{retry_after}s"
      
      # Mark ALL integration users for this tenant as rate limited
      @integrations.each do |integration|
        integration.integration_users.update_all(
          rate_limited_until: Time.current + retry_after.seconds,
          rate_limit_last_retry_after_seconds: retry_after
        )
      end
    end
    
    def extract_retry_after(error)
      # Extract retry-after from error message or headers
      if error.message =~ /retry.*after.*(\d+)/i
        $1.to_i
      else
        60 # Default fallback
      end
    end
    
    def http_get_with_retry(url, token)
      # Use existing HTTP logic with retry
      # (simplified for now - would use the existing http_get method)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'application/json'
      
      response = http.request(request)
      
      case response.code.to_i
      when 200
        JSON.parse(response.body)
      when 429
        raise "Rate limited (429): #{response.body}"
      else
        Rails.logger.warn "[Teams::TenantSyncService] HTTP #{response.code}: #{response.body}"
        nil
      end
    end
    
    def parse_time(str)
      return nil if str.blank?
      Time.parse(str) rescue nil
    end
  end
end