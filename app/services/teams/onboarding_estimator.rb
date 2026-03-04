# app/services/teams/onboarding_estimator.rb
# Accurate Teams onboarding time estimation based on hybrid sync performance

module Teams
  class OnboardingEstimator
    PHASE_A_DAYS = 60
    
    # Performance benchmarks (messages per minute)
    BACKFILL_THROUGHPUT = 150  # 300 messages per channel ÷ 2 minutes
    FORWARD_SYNC_THROUGHPUT = 50  # API pagination ÷ 10 minutes average
    
    def self.estimate_completion(integration)
      new(integration).estimate_completion
    end
    
    def initialize(integration)
      @integration = integration
    end
    
    def estimate_completion
      return { status: :complete, eta: nil } if onboarding_complete?
      
      # Get channel estimates
      channel_estimates = @integration.channels
                                    .where(kind: %w[public_channel private_channel])
                                    .map { |ch| estimate_channel_completion(ch) }
      
      chat_estimates = @integration.channels
                                 .where(kind: %w[im mpim])
                                 .map { |ch| estimate_chat_completion(ch) }
      
      all_estimates = channel_estimates + chat_estimates
      
      # Calculate overall ETA
      total_remaining = all_estimates.sum { |est| est[:messages_remaining] }
      max_eta_minutes = all_estimates.map { |est| est[:eta_minutes] }.max
      
      {
        status: :in_progress,
        total_messages_remaining: total_remaining,
        eta_minutes: max_eta_minutes,
        eta_formatted: format_eta(max_eta_minutes),
        channel_breakdown: all_estimates,
        sync_method: determine_sync_method
      }
    end
    
    private
    
    def onboarding_complete?
      @integration.channels
                  .where(kind: %w[public_channel private_channel im mpim])
                  .where(backfill_complete: [false, nil])
                  .empty?
    end
    
    def estimate_channel_completion(channel)
      # For team channels, estimate based on backfill progress
      if channel.backfill_complete?
        return {
          channel_name: channel.name,
          status: :complete,
          messages_remaining: 0,
          eta_minutes: 0
        }
      end
      
      # Calculate how much 60-day backfill is left
      anchor_ts = channel.backfill_anchor_latest_ts || Time.current.to_f
      oldest_ts = channel.backfill_next_oldest_ts || (Time.current - PHASE_A_DAYS.days).to_f
      target_ts = anchor_ts - PHASE_A_DAYS.days.to_f
      
      # Estimate remaining time window
      remaining_time_window = oldest_ts - target_ts
      remaining_days = [remaining_time_window / 1.day.to_f, 0].max
      
      # Estimate messages based on recent activity
      recent_message_rate = estimate_message_rate_for_channel(channel)
      estimated_remaining = (remaining_days * recent_message_rate).ceil
      
      # Calculate ETA based on throughput
      eta_minutes = (estimated_remaining / BACKFILL_THROUGHPUT).ceil
      
      {
        channel_name: channel.name,
        channel_type: channel.kind,
        status: :in_progress,
        remaining_days: remaining_days.round(1),
        messages_remaining: estimated_remaining,
        eta_minutes: eta_minutes,
        message_rate_per_day: recent_message_rate.round(1)
      }
    end
    
    def estimate_chat_completion(channel)
      # For chats, estimate based on user activity patterns
      if channel.backfill_complete?
        return {
          channel_name: channel.name,
          status: :complete,
          messages_remaining: 0,
          eta_minutes: 0
        }
      end
      
      # Use simpler estimation for chats (typically less volume)
      estimated_chat_messages = estimate_chat_volume(channel)
      eta_minutes = (estimated_chat_messages / BACKFILL_THROUGHPUT).ceil
      
      {
        channel_name: channel.name,
        channel_type: channel.kind,
        status: :in_progress,
        messages_remaining: estimated_chat_messages,
        eta_minutes: eta_minutes
      }
    end
    
    def estimate_message_rate_for_channel(channel)
      # Look at recent message activity to estimate daily volume
      recent_messages = Message.joins(:channel)
                              .where(channels: { external_channel_id: channel.external_channel_id })
                              .where('messages.posted_at > ?', 7.days.ago)
                              .count
      
      # Scale 7-day sample to daily rate
      daily_rate = recent_messages / 7.0
      
      # Add fallback estimates based on channel type
      fallback_rates = {
        'public_channel' => 50,  # messages per day
        'private_channel' => 20,
        'im' => 5,
        'mpim' => 15
      }
      
      # Use observed rate or fallback
      [daily_rate, fallback_rates[channel.kind] || 10].max
    end
    
    def estimate_chat_volume(channel)
      # Conservative estimate for chat backfill
      case channel.kind
      when 'im'
        100  # Typical IM history
      when 'mpim'  
        500  # Group chat history
      else
        50
      end
    end
    
    def determine_sync_method
      # Based on integration age, determine if it will use fast or slow sync
      if @integration.setup_completed_at && @integration.setup_completed_at > 7.days.ago
        :backfill_fast  # 2-minute cycles, high throughput
      else
        :forward_sync   # 10-minute cycles, lower throughput  
      end
    end
    
    def format_eta(minutes)
      return "Complete" if minutes <= 0
      
      if minutes < 60
        "#{minutes} minutes"
      elsif minutes < 1440  # 24 hours
        hours = minutes / 60
        "#{hours.round(1)} hours"
      else
        days = minutes / 1440
        "#{days.round(1)} days"
      end
    end
    
    # Enhanced estimation for dashboard
    def self.workspace_onboarding_summary(workspace)
      teams_integration = workspace.integrations.find_by(kind: "microsoft_teams")
      return nil unless teams_integration
      
      estimate = estimate_completion(teams_integration)
      
      # Add velocity metrics
      recent_velocity = calculate_recent_velocity(teams_integration)
      
      estimate.merge(
        current_velocity: recent_velocity,
        sync_efficiency: calculate_sync_efficiency(teams_integration),
        bottlenecks: identify_bottlenecks(teams_integration)
      )
    end
    
    def self.calculate_recent_velocity(integration)
      # Messages ingested per hour in the last 6 hours
      recent_messages = Message.joins(:channel)
                              .where(channels: { integration_id: integration.id })
                              .where('messages.created_at > ?', 6.hours.ago)
                              .count
      
      recent_messages / 6.0  # messages per hour
    end
    
    def self.calculate_sync_efficiency(integration)
      # Ratio of actual vs theoretical max throughput
      recent_velocity = calculate_recent_velocity(integration)
      theoretical_max = BACKFILL_THROUGHPUT * 60  # per hour
      
      return 0 if theoretical_max == 0
      [(recent_velocity / theoretical_max * 100).round(1), 100].min
    end
    
    def self.identify_bottlenecks(integration)
      bottlenecks = []
      
      # Check rate limiting
      if integration.integration_users.where("rate_limited_until > ?", Time.current).exists?
        bottlenecks << :rate_limited
      end
      
      # Check token availability
      if integration.integration_users.where.not(ms_refresh_token: nil).count < 2
        bottlenecks << :insufficient_tokens
      end
      
      # Check sync method
      if integration.setup_completed_at && integration.setup_completed_at <= 7.days.ago
        bottlenecks << :slow_forward_sync  # Using 10-min cycles instead of 2-min
      end
      
      bottlenecks
    end
  end
end