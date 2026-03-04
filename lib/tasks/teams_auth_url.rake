# lib/tasks/teams_auth_url.rake
# Generates Teams OAuth URL with updated permissions

namespace :teams do
  desc "Generate Teams OAuth URL with sending permissions"
  task :auth_url, [:integration_id] => :environment do |t, args|
    integration_id = (args[:integration_id] || 52).to_i
    
    puts "🔗 Teams OAuth URL Generator"
    puts "============================"
    
    # Find integration to get workspace
    integration = Integration.find_by(id: integration_id)
    unless integration&.microsoft_teams?
      puts "❌ Error: Integration #{integration_id} not found or not a Teams integration"
      exit 1
    end
    
    workspace = integration.workspace
    puts "✅ Found workspace: #{workspace.name} (ID: #{workspace.id})"
    
    # Check environment variables
    unless ENV['TEAMS_CLIENT_ID'].present?
      puts "❌ Error: TEAMS_CLIENT_ID environment variable not set"
      exit 1
    end
    
    puts "✅ Teams Client ID: #{ENV['TEAMS_CLIENT_ID']}"
    
    # Generate OAuth state (simplified for manual flow)
    oauth_nonce = SecureRandom.hex(16)
    
    # Get the redirect URI from routes
    # Use the correct production domain
    base_url = ENV['APP_BASE_URL'] || 'https://app.workplace.io'
    redirect_uri = "#{base_url}/teams_oauth/callback"
    
    # Build auth parameters with ALL permissions including new ones
    auth_params = {
      client_id: ENV['TEAMS_CLIENT_ID'],
      response_type: 'code',
      redirect_uri: redirect_uri,
      response_mode: 'query',
      scope: %w[
        offline_access
        User.Read
        User.Read.All
        Group.Read.All
        Channel.ReadBasic.All
        ChannelMember.Read.All
        ChannelMessage.Read.All
        ChannelMessage.Send
        TeamMember.Read.All
        Chat.Read
        ChatMessage.Send
        Chat.ReadWrite
        Reports.Read.All
      ].join(' '),
      state: oauth_nonce,
      prompt: 'consent'  # Force consent to show new permissions
    }
    
    # Build the authorization URL
    authorize_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?#{auth_params.to_query}"
    
    puts ""
    puts "🎯 AUTHORIZATION URL (copy and paste into browser):"
    puts "=" * 80
    puts authorize_url
    puts "=" * 80
    puts ""
    
    puts "📋 This URL includes these NEW permissions:"
    puts "   • ChannelMessage.Send - Send messages to Teams channels"
    puts "   • ChatMessage.Send - Send chat messages"
    puts "   • Chat.ReadWrite - Read and write chat messages"
    puts ""
    
    puts "🔄 Instructions:"
    puts "1. Copy the URL above and paste it into your browser"
    puts "2. Sign in with your Microsoft account (admin account recommended)"
    puts "3. You'll see a consent screen showing the new permissions"
    puts "4. Click 'Accept' to grant the permissions"
    puts "5. After redirect, you can close the browser"
    puts "6. Test with: rake teams:test_permissions[#{integration_id}]"
    puts ""
    
    puts "⚠️  Note: This will re-consent ALL users in your organization"
    puts "   Existing user tokens will remain valid with new permissions"
    
    # Save the nonce for potential callback handling
    puts ""
    puts "🔑 OAuth State (save this if needed): #{oauth_nonce}"
  end
  
  desc "Generate admin consent URL (organization-wide permissions)"
  task :admin_consent_url => :environment do
    puts "🔗 Teams Admin Consent URL Generator"
    puts "===================================="
    
    unless ENV['TEAMS_CLIENT_ID'].present?
      puts "❌ Error: TEAMS_CLIENT_ID environment variable not set"
      exit 1
    end
    
    # Admin consent URL doesn't need redirect_uri or state
    admin_consent_params = {
      client_id: ENV['TEAMS_CLIENT_ID'],
      scope: %w[
        https://graph.microsoft.com/ChannelMessage.Send
        https://graph.microsoft.com/ChatMessage.Send
        https://graph.microsoft.com/Chat.ReadWrite
      ].join(' ')
    }
    
    admin_consent_url = "https://login.microsoftonline.com/common/adminconsent?#{admin_consent_params.to_query}"
    
    puts ""
    puts "🎯 ADMIN CONSENT URL (copy and paste into browser):"
    puts "=" * 80
    puts admin_consent_url
    puts "=" * 80
    puts ""
    
    puts "📋 This will grant organization-wide consent for:"
    puts "   • ChannelMessage.Send"
    puts "   • ChatMessage.Send"  
    puts "   • Chat.ReadWrite"
    puts ""
    
    puts "🔄 Instructions:"
    puts "1. Copy the URL above and paste it into your browser"
    puts "2. Sign in with your ADMIN Microsoft account"
    puts "3. Grant admin consent for your organization"
    puts "4. Existing users automatically get the new permissions"
    puts "5. Test with: rake teams:test_permissions"
    puts ""
    
    puts "✅ Admin consent is EASIER than individual user consent!"
  end
  
  desc "Show current Teams app permissions"
  task :show_permissions => :environment do
    puts "📋 Current Teams OAuth Permissions"
    puts "================================="
    
    scopes = %w[
      offline_access
      User.Read
      User.Read.All
      Group.Read.All
      Channel.ReadBasic.All
      ChannelMember.Read.All
      ChannelMessage.Read.All
      ChannelMessage.Send
      TeamMember.Read.All
      Chat.Read
      ChatMessage.Send
      Chat.ReadWrite
      Reports.Read.All
    ]
    
    puts ""
    puts "✅ READ Permissions (existing):"
    read_perms = scopes.select { |s| s.include?('Read') || s == 'offline_access' || s == 'Reports.Read.All' }
    read_perms.each { |perm| puts "   • #{perm}" }
    
    puts ""
    puts "🆕 NEW Permissions (for sending messages):"
    new_perms = scopes.select { |s| s.include?('Send') || s == 'Chat.ReadWrite' }
    new_perms.each { |perm| puts "   • #{perm}" }
    
    puts ""
    puts "🎯 To grant these permissions:"
    puts "   rake teams:admin_consent_url     (recommended - organization-wide)"
    puts "   rake teams:auth_url              (individual user consent)"
  end
end