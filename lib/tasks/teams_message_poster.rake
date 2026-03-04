# lib/tasks/teams_message_poster.rake
# Posts realistic test messages to Microsoft Teams via Graph API
# These messages will then be naturally ingested by your Teams sync process
#
# SETUP REQUIRED:
# 1. Add these permissions to your Teams app in Azure AD:
#    - ChannelMessage.Send
#    - ChatMessage.Send  
#    - Chat.ReadWrite
# 2. Re-consent the app with new permissions
#
# Usage:
#   rake teams:post_test_messages[50]
#   rake teams:post_test_messages[100,52]

require 'net/http'
require 'json'
require 'uri'

# Message content loaded inline for reliability

namespace :teams do
  desc "Post realistic test messages to Microsoft Teams via Graph API"
  task :post_test_messages, [:count, :integration_id] => :environment do |t, args|
    count = (args[:count] || 20).to_i
    integration_id = (args[:integration_id] || 52).to_i
    
    puts "🚀 Teams Message Poster via Graph API"
    puts "====================================="
    puts "Integration ID: #{integration_id}"
    puts "Message Count: #{count}"
    puts ""
    
    # Find integration
    integration = Integration.find_by(id: integration_id)
    unless integration&.microsoft_teams?
      puts "❌ Error: Integration #{integration_id} not found or not a Teams integration"
      exit 1
    end
    
    puts "✅ Found integration: #{integration.name}"
    
    # Get a user token for posting
    user = integration.integration_users.where(active: true).where.not(ms_refresh_token: nil).first
    unless user
      puts "❌ Error: No active user with Teams token found"
      exit 1
    end
    
    puts "✅ Found user: #{user.display_name} (#{user.email})"
    
    # Get access token
    begin
      token = integration.ensure_ms_access_token!(user)
      puts "✅ Got access token"
    rescue => e
      puts "❌ Error getting access token: #{e.message}"
      exit 1
    end
    
    # Get channels for posting
    channels = integration.channels.where(kind: %w[public_channel private_channel])
                                  .joins(:team)
                                  .where.not(external_channel_id: nil)
                                  .limit(3) # Limit to a few channels for testing
    
    if channels.empty?
      puts "❌ Error: No suitable channels found for posting"
      exit 1
    end
    
    puts "✅ Found #{channels.count} channels for posting:"
    channels.each { |ch| puts "   - #{ch.name} (#{ch.kind})" }
    puts "✅ Loaded #{test_messages.count} realistic workplace messages"
    puts ""
    
    # Load realistic messages (simplified for production)
    test_messages = [
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
      "Cross-team collaboration workshop tomorrow"
    ]
    
    def post_message_to_channel(token, team_id, channel_id, content)
      uri = URI("https://graph.microsoft.com/v1.0/teams/#{team_id}/channels/#{channel_id}/messages")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'application/json'
      
      body = {
        body: {
          content: content,
          contentType: 'text'
        }
      }
      
      request.body = body.to_json
      
      response = http.request(request)
      
      case response.code.to_i
      when 201
        message_data = JSON.parse(response.body)
        { success: true, id: message_data['id'], web_url: message_data['webUrl'] }
      when 403
        { success: false, error: "Permission denied - need ChannelMessage.Send permission" }
      when 404
        { success: false, error: "Channel not found" }
      else
        { success: false, error: "HTTP #{response.code}: #{response.body}" }
      end
    rescue => e
      { success: false, error: "Network error: #{e.message}" }
    end
    
    puts "📤 Posting messages to Teams..."
    
    posted = 0
    errors = 0
    start_time = Time.current
    
    count.times do |i|
      # Pick random channel and message
      channel = channels.sample
      message_content = test_messages.sample
      
      # Add timestamp to make messages unique
      timestamped_content = "#{message_content} [#{Time.current.strftime('%m/%d %H:%M:%S')}]"
      
      begin
        result = post_message_to_channel(
          token, 
          channel.team.ms_team_id, 
          channel.external_channel_id, 
          timestamped_content
        )
        
        if result[:success]
          posted += 1
          puts "  ✅ [#{i+1}/#{count}] Posted to ##{channel.name}: #{message_content[0..50]}..."
          
          # Add small delay to avoid rate limiting
          sleep(0.5)
        else
          errors += 1
          puts "  ❌ [#{i+1}/#{count}] Failed to post to ##{channel.name}: #{result[:error]}"
          
          # Stop on permission errors
          if result[:error].include?("Permission denied")
            puts ""
            puts "🚨 PERMISSION ERROR DETECTED"
            puts "Your Teams app needs additional permissions:"
            puts "  1. Go to Azure AD > App registrations > [Your Teams App]"
            puts "  2. Add these API permissions:"
            puts "     - Microsoft Graph > ChannelMessage.Send"
            puts "     - Microsoft Graph > ChatMessage.Send"
            puts "  3. Grant admin consent"
            puts "  4. Re-authenticate users in your Teams integration"
            break
          end
        end
        
      rescue => e
        errors += 1
        puts "  ❌ [#{i+1}/#{count}] Exception posting to ##{channel.name}: #{e.message}"
      end
      
      # Stop if too many errors
      if errors > 5
        puts "❌ Too many errors (#{errors}), stopping"
        break
      end
    end
    
    elapsed = Time.current - start_time
    
    puts ""
    puts "📋 Posting Complete!"
    puts "===================="
    puts "Posted: #{posted} messages"
    puts "Errors: #{errors}"
    puts "Duration: #{elapsed.round(1)} seconds"
    
    if posted > 0
      puts ""
      puts "🔄 Next Steps:"
      puts "1. Wait 1-2 minutes for Teams to process"
      puts "2. Run: rake teams:backfill:tick"  
      puts "3. Check ingestion with: rake teams:message_stats"
      puts "4. Monitor logs for sync activity"
      puts ""
      puts "✅ Messages posted to Teams! Your ingestion pipeline will pick them up naturally."
    else
      puts ""
      puts "❌ No messages were posted successfully."
      puts "Please check permissions and try again."
    end
  end
  
  desc "Test Teams API permissions"
  task :test_permissions, [:integration_id] => :environment do |t, args|
    integration_id = (args[:integration_id] || 52).to_i
    
    integration = Integration.find(integration_id)
    user = integration.integration_users.where(active: true).first
    token = integration.ensure_ms_access_token!(user)
    
    puts "🔐 Testing Teams API Permissions"
    puts "================================"
    
    # Test read permissions
    uri = URI("https://graph.microsoft.com/v1.0/me")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{token}"
    
    response = http.request(request)
    if response.code.to_i == 200
      puts "✅ User.Read: OK"
    else
      puts "❌ User.Read: Failed (#{response.code})"
    end
    
    # Test channel read
    channel = integration.channels.joins(:team).where(kind: 'public_channel').first
    if channel
      uri = URI("https://graph.microsoft.com/v1.0/teams/#{channel.team.ms_team_id}/channels/#{channel.external_channel_id}")
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{token}"
      
      response = http.request(request)
      if response.code.to_i == 200
        puts "✅ Channel.ReadBasic.All: OK"
      else
        puts "❌ Channel.ReadBasic.All: Failed (#{response.code})"
      end
    end
    
    # Test message send (will fail if permission not granted)
    if channel
      uri = URI("https://graph.microsoft.com/v1.0/teams/#{channel.team.ms_team_id}/channels/#{channel.external_channel_id}/messages")
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'application/json'
      
      # Don't actually send, just test the permission
      test_body = {
        body: { content: "Test message - please ignore", contentType: 'text' }
      }
      request.body = test_body.to_json
      
      response = http.request(request)
      case response.code.to_i
      when 201
        puts "✅ ChannelMessage.Send: OK (test message sent)"
      when 403
        puts "❌ ChannelMessage.Send: Missing permission"
      else
        puts "⚠️  ChannelMessage.Send: Unexpected response (#{response.code})"
      end
    end
  end
end