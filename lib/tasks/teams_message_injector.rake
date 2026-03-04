# lib/tasks/teams_message_injector.rake
# Creates realistic test messages for Teams integration testing
# 
# Usage:
#   rake teams:inject_test_messages[500]
#   rake teams:inject_test_messages[1000,52]  # 1000 messages for integration 52
#
# Safety: Only runs in development/staging, requires explicit confirmation for production

require 'json'
require 'securerandom'

namespace :teams do
  desc "Inject realistic test messages for Teams integration testing"
  task :inject_test_messages, [:count, :integration_id] => :environment do |t, args|
    count = (args[:count] || 200).to_i
    integration_id = (args[:integration_id] || 52).to_i
    
    # Safety check for production
    if Rails.env.production?
      puts "⚠️  WARNING: Running in PRODUCTION environment!"
      puts "This will create #{count} test messages in integration #{integration_id}"
      print "Are you sure? Type 'YES' to continue: "
      
      confirmation = STDIN.gets.chomp
      unless confirmation == 'YES'
        puts "❌ Cancelled by user"
        exit 1
      end
    end
    
    puts "🚀 Teams Message Injector"
    puts "=========================="
    puts "Environment: #{Rails.env}"
    puts "Integration ID: #{integration_id}"
    puts "Message Count: #{count}"
    puts ""
    
    # Find integration
    integration = Integration.find_by(id: integration_id)
    unless integration&.microsoft_teams?
      puts "❌ Error: Integration #{integration_id} not found or not a Teams integration"
      exit 1
    end
    
    puts "✅ Found integration: #{integration.name} (#{integration.kind})"
    
    # Get users and channels
    users = integration.integration_users.active
    channels = integration.channels.where(kind: %w[public_channel private_channel im mpim])
    
    if users.empty? || channels.empty?
      puts "❌ Error: No active users (#{users.count}) or channels (#{channels.count}) found"
      exit 1
    end
    
    puts "📊 Found #{users.count} users and #{channels.count} channels"
    
    # Sample realistic messages
    sample_messages = [
      "Great work on the quarterly report! The analysis was thorough.",
      "Can we schedule a meeting for next week to review the project status?",
      "Thanks for the quick turnaround on those documents.",
      "The client feedback was very positive. Well done everyone!",
      "Quick question about the budget allocation for Q3.",
      "I'll be working from home tomorrow, but available on Teams.",
      "Please review the draft proposal and provide feedback by EOD.",
      "Happy Friday! Have a great weekend everyone.",
      "The training session was really helpful, thanks for organizing it.",
      "Let's prioritize the customer onboarding improvements.",
      "New team member starts Monday, please help them get oriented.",
      "Quarterly review meeting has been moved to Conference Room B.",
      "I've updated the project timeline in the shared folder.",
      "Great collaboration on the product launch. Numbers look promising!",
      "Coffee chat at 3pm in the kitchen if anyone wants to join.",
      "Security reminder: please enable 2FA if you haven't already.",
      "Project kickoff meeting tomorrow at 2pm in Conference Room A.",
      "Please update your status in the shared spreadsheet.",
      "System upgrade completed successfully, everything looks good.",
      "Welcome aboard! Looking forward to working together.",
      "Don't forget to submit your expense reports by month end.",
      "Team building event planning meeting at 10am.",
      "Great feedback from the customer demo yesterday.",
      "Lunch and learn session next Tuesday on data visualization.",
      "The presentation slides have been shared in the team drive.",
      "Reminder: all-hands meeting moved to 3pm today.",
      "Please join the retrospective meeting to share your thoughts.",
      "New company policy documents are available in the wiki.",
      "Code review completed, looks good to merge.",
      "Database maintenance window scheduled for this weekend."
    ]
    
    message_variations = [
      "%s",
      "%s 👍",
      "@channel %s",
      "%s\n\nLet me know your thoughts!",
      "Update: %s",
      "Question: %s",
      "FYI: %s",
      "Reminder: %s"
    ]
    
    def generate_timestamp
      # Weight toward recent messages: 60% last 7 days, 40% last 30 days
      if rand < 0.6
        rand(7.days.ago..6.hours.ago)
      else
        rand(30.days.ago..7.days.ago)
      end
    end
    
    def encrypt_message(content)
      # Simplified encryption for testing - matches Teams format
      # In real system, this would use proper encryption
      key = SecureRandom.hex(16)
      iv = SecureRandom.hex(8)
      
      {
        "p" => Base64.strict_encode64(content),
        "h" => { "iv" => iv, "k" => key }
      }.to_json
    end
    
    puts "\n📝 Creating messages..."
    
    created = 0
    errors = 0
    start_time = Time.current
    
    Message.transaction do
      count.times do |i|
        begin
          user = users.sample
          channel = channels.sample
          
          # Generate message content
          base_message = sample_messages.sample
          variation = message_variations.sample
          content = variation % base_message
          
          # Generate realistic timestamp
          timestamp = generate_timestamp
          
          # Generate fake Teams message ID (timestamp in ms)
          fake_ts = (timestamp.to_f * 1000000).to_i
          
          # Determine message type
          subtype = case rand
                   when 0..0.85 then nil  # 85% regular messages
                   when 0.85..0.95 then "edited_message"  # 10% edited
                   else "mentioned_message"  # 5% mentions
                   end
          
          # Create message
          message = Message.create!(
            integration_user_id: user.id,
            integration_id: integration.id,
            channel_id: channel.id,
            slack_ts: fake_ts,
            posted_at: timestamp,
            text: encrypt_message(content),
            created_at: timestamp,
            updated_at: timestamp,
            processed: false,
            sent_for_inference_at: nil,
            processed_at: nil,
            slack_thread_ts: nil,
            subtype: subtype,
            edited_at: subtype == "edited_message" ? timestamp + rand(1..120).minutes : nil,
            deleted: false,
            references_processed: false,
            references_processed_at: nil,
            text_purged_at: nil,
            text_original: content,
            original_language: 'en'
          )
          
          created += 1
          
          # Progress indicator
          if (i + 1) % 100 == 0
            elapsed = Time.current - start_time
            rate = created / elapsed
            puts "  ✓ Created #{i + 1}/#{count} messages (#{rate.round(1)}/sec)"
          end
          
        rescue => e
          puts "  ❌ Error creating message #{i + 1}: #{e.message}"
          errors += 1
          
          # Stop if too many errors
          if errors > 10
            puts "❌ Too many errors (#{errors}), stopping"
            break
          end
        end
      end
    end
    
    elapsed = Time.current - start_time
    
    puts "\n🎉 Injection Complete!"
    puts "======================="
    puts "Created: #{created} messages"
    puts "Errors: #{errors}"
    puts "Duration: #{elapsed.round(1)} seconds"
    puts "Rate: #{(created / elapsed).round(1)} messages/second" if elapsed > 0
    
    # Show distribution
    puts "\n📊 Message Distribution:"
    Message.joins(:integration_user)
           .where(integration_id: integration.id)
           .where('messages.created_at >= ?', start_time - 1.minute)
           .group('integration_users.display_name')
           .order('count_all DESC')
           .count.each do |name, msg_count|
      puts "  #{name}: #{msg_count}"
    end
    
    puts "\n📈 Channel Distribution:"
    Message.joins(:channel)
           .where(integration_id: integration.id)
           .where('messages.created_at >= ?', start_time - 1.minute)
           .group('channels.name')
           .order('count_all DESC')
           .count.each do |name, msg_count|
      puts "  #{name}: #{msg_count}"
    end
    
    # Show total messages now
    total_messages = Message.where(integration_id: integration.id).count
    puts "\n📋 Total messages in integration: #{total_messages}"
    
    puts "\n🚀 Ready for testing!"
    puts "You can now run: rake teams:backfill:tick"
    puts "Or trigger analysis pipeline to process the new messages."
  end
  
  desc "Show Teams integration message statistics"
  task :message_stats, [:integration_id] => :environment do |t, args|
    integration_id = (args[:integration_id] || 52).to_i
    
    integration = Integration.find_by(id: integration_id)
    unless integration&.microsoft_teams?
      puts "❌ Error: Integration #{integration_id} not found or not a Teams integration"
      exit 1
    end
    
    puts "📊 Teams Integration Stats: #{integration.name}"
    puts "=" * 50
    
    total = Message.where(integration_id: integration.id).count
    last_24h = Message.where(integration_id: integration.id)
                     .where('created_at >= ?', 24.hours.ago).count
    processed = Message.where(integration_id: integration.id, processed: true).count
    
    puts "Total Messages: #{total}"
    puts "Last 24 hours: #{last_24h}"
    puts "Processed: #{processed} (#{((processed.to_f / total) * 100).round(1)}%)" if total > 0
    
    if total > 0
      earliest = Message.where(integration_id: integration.id).minimum(:posted_at)
      latest = Message.where(integration_id: integration.id).maximum(:posted_at)
      puts "Date Range: #{earliest.strftime('%Y-%m-%d')} → #{latest.strftime('%Y-%m-%d')}"
    end
    
    puts "\nUsers:"
    Message.joins(:integration_user)
           .where(integration_id: integration.id)
           .group('integration_users.display_name')
           .order('count_all DESC')
           .count.each do |name, count|
      puts "  #{name}: #{count}"
    end
  end
end