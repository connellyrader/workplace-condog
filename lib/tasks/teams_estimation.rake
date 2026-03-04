# lib/tasks/teams_estimation.rake
# Teams onboarding estimation and progress tracking

namespace :teams do
  desc "Show onboarding progress and ETA for Teams integration"
  task :onboarding_status, [:integration_id] => :environment do |t, args|
    integration_id = (args[:integration_id] || 52).to_i
    
    integration = Integration.find(integration_id)
    estimate = Teams::OnboardingEstimator.estimate_completion(integration)
    
    puts "📊 Teams Onboarding Status"
    puts "=========================="
    puts "Integration: #{integration.name} (#{integration_id})"
    puts "Setup completed: #{integration.setup_completed_at}"
    puts ""
    
    case estimate[:status]
    when :complete
      puts "✅ STATUS: COMPLETE"
      puts "All channels have completed 30-day backfill"
    when :in_progress
      puts "🔄 STATUS: IN PROGRESS"
      puts "Messages remaining: #{estimate[:total_messages_remaining]}"
      puts "Estimated completion: #{estimate[:eta_formatted]}"
      puts "Current velocity: #{estimate[:current_velocity]&.round(1)} messages/hour"
      puts "Sync efficiency: #{estimate[:sync_efficiency]}%"
      puts "Sync method: #{estimate[:sync_method]}"
      
      if estimate[:bottlenecks]&.any?
        puts "⚠️  Bottlenecks: #{estimate[:bottlenecks].join(', ')}"
      end
      
      puts ""
      puts "📋 Channel Breakdown:"
      estimate[:channel_breakdown]&.each do |ch|
        if ch[:status] == :complete
          puts "  ✅ #{ch[:channel_name]} (#{ch[:channel_type]}): Complete"
        else
          puts "  🔄 #{ch[:channel_name]} (#{ch[:channel_type]}):"
          puts "     #{ch[:messages_remaining]} messages remaining"
          puts "     #{ch[:eta_minutes]} minutes estimated"
          if ch[:remaining_days]
            puts "     #{ch[:remaining_days]} days of history left"
          end
        end
      end
    end
    
    puts ""
    puts "🎯 Recommendations:"
    
    case estimate[:sync_method]
    when :backfill_fast
      puts "  • Integration is using fast backfill (2-minute cycles)"
      puts "  • Optimal performance for new integration"
    when :forward_sync
      puts "  • Integration is using slower forward sync (10-minute cycles)"
      puts "  • Consider forcing backfill mode for faster completion:"
      puts "    Integration.find(#{integration_id}).channels.update_all(backfill_complete: false)"
    end
    
    if estimate[:sync_efficiency] && estimate[:sync_efficiency] < 50
      puts "  • Low sync efficiency detected"
      puts "  • Check for rate limiting or API issues"
    end
  end
  
  desc "Compare estimation accuracy with actual performance"
  task :estimation_accuracy => :environment do
    puts "📈 Teams Estimation Accuracy Analysis"
    puts "===================================="
    
    Integration.where(kind: "microsoft_teams").each do |integration|
      puts "\\nIntegration #{integration.id} (#{integration.name}):"
      
      # Current state
      total_messages = integration.messages.count
      setup_time = integration.setup_completed_at
      
      if setup_time
        elapsed_hours = (Time.current - setup_time) / 1.hour
        actual_velocity = total_messages / elapsed_hours
        
        puts "  Actual performance:"
        puts "    Total messages: #{total_messages}"
        puts "    Elapsed time: #{elapsed_hours.round(1)} hours"  
        puts "    Actual velocity: #{actual_velocity.round(1)} messages/hour"
        
        # Compare with estimates
        estimate = Teams::OnboardingEstimator.estimate_completion(integration)
        estimated_velocity = estimate[:current_velocity] || 0
        
        accuracy = estimated_velocity > 0 ? ((actual_velocity / estimated_velocity) * 100).round(1) : 0
        puts "  Estimation accuracy: #{accuracy}% (estimated: #{estimated_velocity.round(1)} msg/hr)"
      else
        puts "  No setup time recorded"
      end
    end
  end
  
  desc "Simulate onboarding time for different scenarios"
  task :simulate_scale => :environment do
    puts "🏭 Teams Onboarding Scale Simulation"
    puts "==================================="
    
    scenarios = [
      { tenants: 10, channels_per_tenant: 20, messages_per_day: 100 },
      { tenants: 100, channels_per_tenant: 15, messages_per_day: 50 },
      { tenants: 500, channels_per_tenant: 10, messages_per_day: 30 },
      { tenants: 1000, channels_per_tenant: 8, messages_per_day: 20 }
    ]
    
    scenarios.each do |scenario|
      puts "\\n📊 Scenario: #{scenario[:tenants]} tenants"
      
      total_channels = scenario[:tenants] * scenario[:channels_per_tenant]
      total_30d_messages = total_channels * scenario[:messages_per_day] * 30
      
      puts "  Total channels: #{total_channels}"
      puts "  Total 30-day messages: #{total_30d_messages}"
      
      # Estimate time with current architecture
      backfill_minutes = total_30d_messages / BACKFILL_THROUGHPUT
      forward_minutes = total_30d_messages / (FORWARD_SYNC_THROUGHPUT * 6) # 10-min cycles
      
      puts "  Onboarding time (fast backfill): #{(backfill_minutes / 60).round(1)} hours"
      puts "  Onboarding time (slow forward): #{(forward_minutes / 60).round(1)} hours"
      
      # Parallel processing estimates
      if scenario[:tenants] > 1
        parallel_backfill = backfill_minutes / [scenario[:tenants], 10].min  # Max 10 parallel
        puts "  With parallel processing (10 tenants): #{(parallel_backfill / 60).round(1)} hours"
      end
    end
    
    puts ""
    puts "🎯 Scale Optimization Recommendations:"
    puts "  1. Prioritize new integrations for fast backfill mode"
    puts "  2. Implement parallel tenant processing (max 10 concurrent)"
    puts "  3. Increase forward sync frequency from 10min to 2min"
    puts "  4. Use tenant-level deduplication to reduce API calls"
  end
  
  desc "Show real-time sync progress for active integration"
  task :progress, [:integration_id] => :environment do |t, args|
    integration_id = (args[:integration_id] || 52).to_i
    integration = Integration.find(integration_id)
    
    puts "⏱️  Real-Time Sync Progress"
    puts "=========================="
    puts "Integration: #{integration.name} (#{integration_id})"
    
    # Show current message count
    current_count = integration.messages.count
    puts "Current messages: #{current_count}"
    
    # Show velocity over last hour
    last_hour_count = integration.messages.where('created_at > ?', 1.hour.ago).count
    puts "Messages in last hour: #{last_hour_count}"
    puts "Current velocity: #{last_hour_count} messages/hour"
    
    # Show channel progress
    puts ""
    puts "📋 Channel Progress:"
    
    integration.channels.where(kind: %w[public_channel private_channel im mpim]).each do |channel|
      recent_messages = channel.messages.where('created_at > ?', 1.hour.ago).count
      total_messages = channel.messages.count
      
      status = channel.backfill_complete? ? "✅" : "🔄"
      puts "  #{status} #{channel.name}: #{total_messages} total, +#{recent_messages} last hour"
    end
    
    # Prediction for next check
    if last_hour_count > 0
      puts ""
      puts "🔮 Prediction:"
      puts "At current velocity (#{last_hour_count}/hr), expect #{last_hour_count/6} messages in next 10 minutes"
    end
  end
end