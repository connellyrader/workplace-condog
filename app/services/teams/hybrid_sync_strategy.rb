# app/services/teams/hybrid_sync_strategy.rb
# Hybrid sync: tenant-level for forward sync, integration-level for backfill

require "timeout"

module Teams
  class HybridSyncStrategy
    def self.sync_all!(max_per_tick: 25, stale_after: 60.minutes, timeout_s: 120)
      max_per_tick = max_per_tick.to_i
      max_per_tick = 1 if max_per_tick <= 0

      # 1. Handle backfill needs PER integration (can't be shared)
      handle_integration_backfills(max_per_tick: max_per_tick, timeout_s: timeout_s)

      # 2. Handle forward sync PER tenant (can be shared)
      handle_tenant_forward_syncs(max_per_tick: max_per_tick, stale_after: stale_after, timeout_s: timeout_s)
    end

    def self.handle_integration_backfills(max_per_tick:, timeout_s:)
      integrations_needing_backfill = Integration
        .joins(:workspace)
        .where(kind: "microsoft_teams")
        .where(workspaces: { archived_at: nil })
        .left_outer_joins(:channels)
        .where(
          "integrations.setup_completed_at IS NULL OR integrations.setup_completed_at > ? OR channels.id IS NULL OR channels.backfill_complete = false OR channels.backfill_complete IS NULL",
          7.days.ago
        )
        .distinct
        .limit(max_per_tick)

      Rails.logger.info "[Teams::HybridSyncStrategy] Backfill integrations this tick=#{integrations_needing_backfill.size} max_per_tick=#{max_per_tick}"

      integrations_needing_backfill.each do |integration|
        # If setup never completed (or channel inventory is empty), bootstrap directory/channels first.
        if integration.setup_completed_at.nil? || integration.channels.count.zero?
          begin
            Rails.logger.info "[Teams::HybridSyncStrategy] Running setup bootstrap for integration #{integration.id}"
            Timeout.timeout(timeout_s) do
              Teams::IntegrationSetup.call(integration)
            end

            integration.reload
            integration.update_columns(
              setup_users_count: IntegrationUser.where(integration_id: integration.id, is_bot: false, active: true).count,
              setup_channels_count: Channel.where(integration_id: integration.id, kind: "public_channel", is_archived: false).count,
              setup_memberships_count: ChannelMembership.where(integration_id: integration.id, left_at: nil).count,
              setup_status: "complete",
              setup_step: "complete",
              setup_progress: 100,
              setup_completed_at: Time.current,
              setup_error: nil
            )
          rescue Timeout::Error
            Rails.logger.warn "[Teams::HybridSyncStrategy] Setup bootstrap timeout for integration #{integration.id} after #{timeout_s}s"
            next
          rescue => e
            Rails.logger.error "[Teams::HybridSyncStrategy] Setup bootstrap failed for integration #{integration.id}: #{e.message}"
            next
          end
        end

        Rails.logger.info "[Teams::HybridSyncStrategy] Running backfill for integration #{integration.id} (#{integration.name})"

        begin
          Timeout.timeout(timeout_s) do
            Teams::HistorySyncService.new(integration).run_backfill!
          end
        rescue Timeout::Error
          Rails.logger.warn "[Teams::HybridSyncStrategy] Backfill timeout for integration #{integration.id} after #{timeout_s}s"
        rescue => e
          Rails.logger.error "[Teams::HybridSyncStrategy] Backfill failed for integration #{integration.id}: #{e.message}"
        end
      end
    end

    def self.handle_tenant_forward_syncs(max_per_tick:, stale_after:, timeout_s:)
      tenants_needing_sync = get_tenants_needing_forward_sync(stale_after: stale_after).first(max_per_tick)

      Rails.logger.info "[Teams::HybridSyncStrategy] Forward tenants this tick=#{tenants_needing_sync.size} max_per_tick=#{max_per_tick} stale_after=#{stale_after.to_i}s"

      tenants_needing_sync.each do |tenant_data|
        tenant_id = tenant_data[:tenant_id]

        begin
          Timeout.timeout(timeout_s) do
            Teams::TenantSyncService.sync_tenant!(tenant_id)
          end
        rescue Timeout::Error
          Rails.logger.warn "[Teams::HybridSyncStrategy] Forward sync timeout for tenant #{tenant_id} after #{timeout_s}s"
        rescue => e
          Rails.logger.error "[Teams::HybridSyncStrategy] Forward sync failed for tenant #{tenant_id}: #{e.message}"
        end
      end
    end

    private

    def self.get_tenants_needing_forward_sync(stale_after: 60.minutes)
      # Get tenants where ANY integration has stale forward sync
      Integration
        .joins(:workspace)
        .where(kind: "microsoft_teams")
        .where(workspaces: { archived_at: nil })
        .joins(:channels)
        .where("channels.last_audit_at IS NULL OR channels.last_audit_at < ?", Time.current - stale_after)
        .where("channels.backfill_complete = true")
        .group(:ms_tenant_id)
        .select(:ms_tenant_id)
        .map { |i| { tenant_id: i.ms_tenant_id } }
    end
  end
end

# Enhanced TenantSyncService with per-integration state awareness
module Teams
  class TenantSyncService
    def distribute_messages_to_integrations(external_channel_id, messages)
      target_channels = Channel.joins(integration: :workspace)
                              .where(integrations: { ms_tenant_id: @tenant_id })
                              .where(workspaces: { archived_at: nil })
                              .where(external_channel_id: external_channel_id)
      
      Rails.logger.info "[Teams::TenantSyncService] Distributing #{messages.count} messages to #{target_channels.count} channels"
      
      target_channels.group_by(&:integration).each do |integration, channels|
        # Each integration gets its own tracking
        channels.each do |channel|
          # Only store messages this integration hasn't seen yet
          integration_last_sync = get_integration_last_sync(integration, channel)
          
          new_messages = messages.select do |msg|
            msg_time = parse_time(msg["createdDateTime"])
            msg_time && msg_time.to_f > integration_last_sync
          end
          
          if new_messages.any?
            Rails.logger.info "[Teams::TenantSyncService] Integration #{integration.id}: #{new_messages.count} new messages for channel #{channel.name}"
            
            sync_service = Teams::HistorySyncService.new(integration)
            
            new_messages.each do |msg|
              begin
                sync_service.send(:upsert_message_from_ms, msg, channel)
              rescue => e
                Rails.logger.warn "[Teams::TenantSyncService] Failed to store message for integration #{integration.id}: #{e.message}"
              end
            end
            
            # Update this integration's sync timestamp
            update_integration_sync_timestamp(integration, channel, new_messages)
          else
            Rails.logger.info "[Teams::TenantSyncService] Integration #{integration.id}: No new messages for channel #{channel.name}"
          end
        end
      end
    end
    
    private
    
    def get_integration_last_sync(integration, channel)
      # Use integration-specific tracking, not shared timestamps
      integration_channel = integration.channels.find_by(external_channel_id: channel.external_channel_id)
      integration_channel&.forward_newest_ts || 0
    end
    
    def update_integration_sync_timestamp(integration, channel, messages)
      newest_ts = messages.map { |m| parse_time(m["createdDateTime"])&.to_f }.compact.max
      
      if newest_ts
        integration_channel = integration.channels.find_by(external_channel_id: channel.external_channel_id)
        
        if integration_channel
          current_newest = integration_channel.forward_newest_ts || 0
          integration_channel.update_columns(
            forward_newest_ts: [current_newest, newest_ts].max,
            last_audit_at: Time.current
          )
        end
      end
    end
  end
end