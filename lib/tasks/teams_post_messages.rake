# lib/tasks/teams_post_messages.rake
# Posts realistic test messages to Microsoft Teams via Graph API

require 'net/http'
require 'json'
require 'uri'

namespace :teams do
  desc "Post test messages to Microsoft Teams (working version)"
  task :post_messages, [:count, :integration_id] => :environment do |t, args|
    count = (args[:count] || 10).to_i
    integration_id = (args[:integration_id] || 52).to_i
    
    puts "🚀 Teams Message Poster (Working Version)"
    puts "========================================"
    puts "Integration ID: #{integration_id}"
    puts "Message Count: #{count}"
    puts ""
    
    # Find integration
    integration = Integration.find(integration_id)
    puts "✅ Found integration: #{integration.name}"
    
    # Get user and token
    user = integration.integration_users.where(active: true).where.not(ms_refresh_token: nil).first
    unless user
      puts "❌ Error: No active user with Teams token found"
      exit 1
    end
    puts "✅ Found user: #{user.display_name}"
    
    token = integration.ensure_ms_access_token!(user)
    puts "✅ Got access token"
    
    # Get team-based channels (public/private) 
    team_channels = integration.channels.joins(:team).where(kind: %w[public_channel private_channel]).where.not(external_channel_id: nil).limit(3)
    
    # Get IM channels (don't need team association)
    im_channels = integration.channels.where(kind: %w[im mpim]).where.not(external_channel_id: nil).limit(3)
    
    # Combine both types for comprehensive testing
    all_channels = team_channels.to_a + im_channels.to_a
    channels = all_channels.take(6)
    if channels.empty?
      puts "❌ Error: No suitable channels found"
      exit 1
    end
    
    puts "✅ Found #{channels.count} channels:"
    channels.each { |ch| puts "   - #{ch.name} (#{ch.kind})" }
    puts ""
    
    # Test messages array (mix of public and IM appropriate content)
    messages = [
      "Project status update completed successfully",
      "Team meeting scheduled for tomorrow at 2pm", 
      "Great work on the quarterly review presentation",
      "Can someone help debug this API integration issue?",
      "Coffee break chat - how's everyone's day going?",
      "New team member starting next week",
      "Code review completed, ready for deployment",
      "Thanks for the quick turnaround on those reports",
      "System maintenance window scheduled for weekend",
      "Client feedback has been very positive",
      "Budget planning session moved to Thursday",
      "Performance metrics looking good this quarter",
      "Quick question about the database optimization",
      "Sprint retrospective action items posted",
      "Security patch deployment completed",
      "User testing feedback incorporated into design",
      "Happy Friday! Have a great weekend everyone",
      "Documentation updated with latest API changes",
      "Monitoring alerts configured for new features",
      "Cross-team collaboration workshop tomorrow",
      # IM-specific messages
      "Hey, do you have 5 minutes for a quick call?",
      "Can you review this draft when you get a chance?",
      "Thanks for helping with that bug fix earlier!",
      "Are you free for lunch tomorrow?",
      "Quick heads up about the client meeting change",
      "Got your message, will respond after the meeting",
      "Perfect, that solution works great!",
      "Can you send me the link to that document?",
      "Just wanted to confirm our 1:1 for Thursday",
      "Thanks for the code review feedback!"
    ]
    
    puts "📤 Posting messages to Teams..."
    
    posted = 0
    errors = 0
    
    count.times do |i|
      # Pick random channel and message
      channel = channels.sample
      message_content = messages.sample
      
      # Add timestamp to make unique
      timestamped_content = "#{message_content} [#{Time.current.strftime('%m/%d %H:%M:%S')}]"
      
      begin
        # Use different API endpoints for different channel types
        if channel.kind.in?(['im', 'mpim'])
          # For IMs/MPIMs, use /chats endpoint
          uri = URI("https://graph.microsoft.com/v1.0/chats/#{channel.external_channel_id}/messages")
        else
          # For team channels, use /teams endpoint  
          uri = URI("https://graph.microsoft.com/v1.0/teams/#{channel.team.ms_team_id}/channels/#{channel.external_channel_id}/messages")
        end
        
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{token}"
        request['Content-Type'] = 'application/json'
        
        body = {
          body: {
            content: timestamped_content,
            contentType: 'text'
          }
        }
        
        request.body = body.to_json
        response = http.request(request)
        
        if response.code.to_i == 201
          posted += 1
          puts "  ✅ [#{i+1}/#{count}] Posted to ##{channel.name}: #{message_content[0..50]}..."
          sleep(0.5) # Rate limiting
        else
          errors += 1
          puts "  ❌ [#{i+1}/#{count}] Failed (HTTP #{response.code}): #{response.body[0..100]}..."
        end
        
      rescue => e
        errors += 1
        puts "  ❌ [#{i+1}/#{count}] Exception: #{e.message}"
      end
      
      break if errors > 5
    end
    
    puts ""
    puts "📋 Complete!"
    puts "Posted: #{posted} messages"
    puts "Errors: #{errors}"
    
    if posted > 0
      puts ""
      puts "✅ Check your Teams app - messages should be visible!"
      puts "🔄 Next: Run your sync to ingest them:"
      puts "   rake teams:backfill:tick"
    end
  end
end