# lib/tasks/teams_tenant_sync.rake
# Tenant-level sync that eliminates duplicate API calls

namespace :teams do
  desc "Sync all Teams tenants (one API call per tenant, distribute to all integrations)"
  task :tenant_sync => :environment do
    puts "🏢 Teams Tenant-Level Sync"
    puts "========================="
    
    # Show what we'll be syncing
    tenant_info = Integration.joins(:workspace)
                            .where(kind: "microsoft_teams")
                            .where(workspaces: { archived_at: nil })
                            .where.not(ms_tenant_id: nil)
                            .group(:ms_tenant_id)
                            .joins("LEFT JOIN integrations i2 ON i2.ms_tenant_id = integrations.ms_tenant_id")
                            .select("integrations.ms_tenant_id, COUNT(DISTINCT integrations.id) as integration_count")
    
    tenant_info.each do |info|
      integrations = Integration.joins(:workspace)
                                .where(ms_tenant_id: info.ms_tenant_id)
                                .where(workspaces: { archived_at: nil })
                                .pluck(:id, :name)
      puts "Tenant #{info.ms_tenant_id}:"
      puts "  #{info.integration_count} integrations: #{integrations.map { |id, name| "#{id} (#{name})" }.join(', ')}"
    end
    
    puts ""
    
    Teams::TenantSyncService.sync_all_tenants!
    puts "✅ Tenant sync completed"
  end
  
  desc "Sync specific tenant"
  task :sync_tenant, [:tenant_id] => :environment do |t, args|
    tenant_id = args[:tenant_id]
    unless tenant_id
      puts "❌ Error: Please provide tenant_id"
      puts "Usage: rake teams:sync_tenant[97c74186-6316-49f6-8586-029493779c3f]"
      exit 1
    end
    
    Teams::TenantSyncService.sync_tenant!(tenant_id)
    puts "✅ Tenant #{tenant_id} synced"
  end
  
  desc "Show tenant information"
  task :tenant_info => :environment do
    puts "📋 Teams Tenant Information"
    puts "=========================="
    
    Integration.joins(:workspace)
               .where(kind: "microsoft_teams")
               .where(workspaces: { archived_at: nil })
               .where.not(ms_tenant_id: nil)
               .group(:ms_tenant_id)
               .includes(:integration_users, :channels)
               .each do |integration|
      
      tenant_id = integration.ms_tenant_id
      all_integrations = Integration.joins(:workspace)
                                   .where(ms_tenant_id: tenant_id)
                                   .where(workspaces: { archived_at: nil })
      
      puts "\\nTenant: #{tenant_id}"
      puts "  Integrations: #{all_integrations.count}"
      
      all_integrations.each do |int|
        puts "    #{int.id}: #{int.name} (#{int.channels.count} channels, #{int.integration_users.count} users)"
      end
      
      # Show shared channels
      shared_channels = Channel.joins(:integration)
                              .where(integrations: { ms_tenant_id: tenant_id })
                              .group(:external_channel_id)
                              .having("COUNT(DISTINCT integration_id) > 1")
                              .count
      
      puts "  Shared channels: #{shared_channels.count}"
      shared_channels.each do |external_id, integration_count|
        puts "    #{external_id}: shared by #{integration_count} integrations"
      end
      
      # Rate limiting status
      rate_limited = Integration.joins(:integration_users)
                               .where(integrations: { ms_tenant_id: tenant_id })
                               .where("integration_users.rate_limited_until > ?", Time.current)
                               .count("DISTINCT integrations.id")
      
      puts "  Rate limited integrations: #{rate_limited}"
    end
  end
end