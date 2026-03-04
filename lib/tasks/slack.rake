namespace :slack do
  desc "Test Slack rate limits across multiple user tokens and print messages"
  task rate_limit: :environment do
    require 'net/http'
    require 'json'

    SLACK_USER_TOKENS = [
      #removed tokens for security
    ]

    def fetch_first_available_channel(token)
      uri = URI("https://slack.com/api/conversations.list?types=public_channel&limit=15")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{token}"

      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
      json = JSON.parse(res.body)

      if json["ok"] && json["channels"]&.any?
        json["channels"].first["id"]
      else
        nil
      end
    end

    def fetch_messages(token, channel_id)
      uri = URI("https://slack.com/api/conversations.history?channel=#{channel_id}&limit=1000")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{token}"

      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
      [res.code, JSON.parse(res.body)]
    end

    puts "🔍 Starting Slack rate limit test at #{Time.now}"
    responses = []

    threads = SLACK_USER_TOKENS.each_with_index.map do |token, i|
      Thread.new do
        channel_id = fetch_first_available_channel(token)

        if channel_id.nil?
          puts "❌ Token ##{i + 1} (#{token[0..10]}...): No public channel found."
          responses << { token: token, code: "N/A", ok: false, error: "no_channel" }
          next
        end

        code, json = fetch_messages(token, channel_id)

        if code == "429"
          retry_after = json["retry_after"] || "?"
          puts "⏳ Token ##{i + 1} (#{token[0..10]}...): RATE LIMITED (Retry after #{retry_after}s)"
          responses << { token: token, code: code, ok: false, error: "rate_limited", retry_after: retry_after }
        elsif json["ok"]
          puts "✅ Token ##{i + 1} (#{token[0..10]}...): HTTP #{code}, ok: true — found #{json['messages']&.size} messages"

          json["messages"].each_with_index do |msg, j|
            user = msg["user"] || "unknown"
            text = msg["text"]&.gsub("\n", ' ') || "[no text]"
            ts   = msg["ts"]
            puts "    • Message #{j + 1}: [#{ts}] <#{user}>: #{text[0..80]}"
          end

          responses << { token: token, code: code, ok: true, error: nil }
        else
          puts "❌ Token ##{i + 1} (#{token[0..10]}...): HTTP #{code}, ok: false, error: #{json['error']}"
          responses << { token: token, code: code, ok: false, error: json['error'] }
        end
      end
    end

    threads.each(&:join)

    puts "\n📊 Summary:"
    responses.each_with_index do |r, i|
      puts "Token ##{i + 1} (#{r[:token][0..10]}...): #{r[:code]} #{r[:ok]} (#{r[:error]})"
    end
  end

  desc "Test: count Slack messages for workspace users that belong to groups (last 30 days)"
  task estimate_group_user_message_counts: :environment do
    # ------------------------------------------------------------------
    # How to run:
    #   WORKSPACE_ID=123 bundle exec rake slack:estimate_group_user_message_counts
    #
    # Optional:
    #   TOKEN_WORKSPACE_USER_ID=456 WORKSPACE_ID=123 bundle exec rake ...
    #   to force using a specific workspace_user's slack_history_token.
    # ------------------------------------------------------------------

    # You can still hardcode if you want, or use ENV:
    workspace_id = (ENV['WORKSPACE_ID'] || 1).to_i
    workspace    = Workspace.find(workspace_id)

    # Time window: last 30 days
    cutoff_time = 30.days.ago
    cutoff_ts   = cutoff_time.to_f # Slack ts is seconds as float string

    puts "Restricting messages to last 30 days since #{cutoff_time} (ts=#{cutoff_ts})"
    puts

    # ------------------------------------------------------------------
    # 1) Find all workspace_users that are in ANY group for this workspace
    # ------------------------------------------------------------------
    groups_in_workspace = Group.where(workspace_id: workspace.id)

    if groups_in_workspace.empty?
      puts "No groups found for workspace #{workspace.id}."
      next
    end

    group_member_workspace_user_ids = GroupMember
      .where(group_id: groups_in_workspace.select(:id))
      .distinct
      .pluck(:workspace_user_id)

    if group_member_workspace_user_ids.empty?
      puts "No group_members found for workspace #{workspace.id}."
      next
    end

    target_workspace_users = WorkspaceUser
      .where(id: group_member_workspace_user_ids, workspace_id: workspace.id)
      .where.not(slack_user_id: nil)

    target_slack_user_ids = target_workspace_users.pluck(:slack_user_id).uniq

    if target_slack_user_ids.empty?
      puts "No grouped workspace_users have slack_user_id in workspace #{workspace.id}."
      next
    end

    puts "Workspace #{workspace.id}:"
    puts "  Groups:                        #{groups_in_workspace.count}"
    puts "  Group members:                 #{group_member_workspace_user_ids.size}"
    puts "  Slack users in groups (uniq):  #{target_slack_user_ids.size}"
    puts

    # ------------------------------------------------------------------
    # 2) Pick a slack_history_token (prefer from env; otherwise any in workspace)
    # ------------------------------------------------------------------
    token_owner =
      if ENV['TOKEN_WORKSPACE_USER_ID']
        WorkspaceUser.find(ENV['TOKEN_WORKSPACE_USER_ID'])
      else
        WorkspaceUser
          .where(workspace_id: workspace.id)
          .where.not(slack_history_token: nil)
          .first
      end

    unless token_owner&.slack_history_token.present?
      raise "No workspace_user with slack_history_token found. " \
            "Set TOKEN_WORKSPACE_USER_ID=... or ensure someone has a history token."
    end

    slack_token = token_owner.slack_history_token
    puts "Using slack_history_token from workspace_user ##{token_owner.id} (#{token_owner.email || token_owner.real_name})"
    puts

    client = Slack::Web::Client.new(token: slack_token)

    # ------------------------------------------------------------------
    # 3) Fetch all channels in the workspace via Slack API
    # ------------------------------------------------------------------
    channel_ids = []
    cursor      = nil

    begin
      resp = client.conversations_list(
        types: 'public_channel,private_channel',
        limit: 1000,
        cursor: cursor
      )

      (resp['channels'] || []).each do |ch|
        channel_ids << ch['id']
      end

      cursor = resp.dig('response_metadata', 'next_cursor')
    end while cursor && !cursor.empty?

    puts "Discovered #{channel_ids.size} channels in Slack workspace."
    puts

    # ------------------------------------------------------------------
    # 4) Scan messages in each channel and count only those authored by
    #    users that are in ANY group, within last 30 days
    # ------------------------------------------------------------------
    target_set = target_slack_user_ids.to_set
    counts     = Hash.new(0)

    channel_ids.each_with_index do |channel_id, idx|
      puts "Scanning channel #{idx + 1}/#{channel_ids.size}: #{channel_id}"

      history_cursor = nil

      begin
        history_resp = client.conversations_history(
          channel: channel_id,
          limit: 1000,
          cursor: history_cursor,
          oldest: cutoff_ts.to_s  # only messages >= this ts
        )

        messages = history_resp['messages'] || []

        messages.each do |msg|
          # Extra guard in case Slack ever returns older stuff
          ts = msg['ts']
          next unless ts
          next if ts.to_f < cutoff_ts

          slack_user_id = msg['user']
          next unless slack_user_id && target_set.include?(slack_user_id)

          counts[slack_user_id] += 1
        end

        history_cursor = history_resp.dig('response_metadata', 'next_cursor')
      end while history_cursor && !history_cursor.empty?
    end

    # ------------------------------------------------------------------
    # 5) Output results: one line per grouped user with count of messages
    # ------------------------------------------------------------------
    ws_users_by_slack_id = target_workspace_users.index_by(&:slack_user_id)

    puts
    puts "=== Message counts for workspace users in groups (author-only, last 30 days) ==="
    total = counts.values.sum
    puts "Total messages across all grouped Slack users (30 days): #{total}"
    puts

    counts
      .sort_by { |(_slack_id, count)| -count }
      .each do |slack_id, count|
        wu = ws_users_by_slack_id[slack_id]

        label_parts = []
        label_parts << wu.real_name    if wu&.real_name.present?
        label_parts << wu.display_name if wu&.display_name.present?
        label_parts << wu.email        if wu&.email.present?
        label_parts << "Slack: #{slack_id}" if label_parts.empty?

        label = label_parts.compact.join(" | ")
        puts "#{label.ljust(60)}  #{count}"
      end

    puts
    puts "Done."
  end



  desc "Count messages from PUBLIC channels in the last 30 days for a workspace"
  task public_message_counts_30d: :environment do
    # Usage:
    #   WORKSPACE_ID=1 bundle exec rake slack:public_message_counts_30d
    # Optional:
    #   TOKEN_WORKSPACE_USER_ID=123 WORKSPACE_ID=1 bundle exec rake slack:public_message_counts_30d
    #
    # This uses the same logic as the time estimator:
    # - Pick a workspace_user with a slack_history_token
    # - Fetch ALL public channels visible to that user
    # - For each channel, walk conversations.history from 30.days.ago forward
    # - Count messages and print per-channel + total

    workspace_id = 1
    unless workspace_id && workspace_id > 0
      abort "Please set WORKSPACE_ID, e.g. WORKSPACE_ID=1 bundle exec rake slack:public_message_counts_30d"
    end

    workspace = Workspace.find_by(id: workspace_id)
    abort "Workspace #{workspace_id} not found" unless workspace

    cutoff_time = 30.days.ago
    cutoff_ts   = cutoff_time.to_f

    puts "=== Slack PUBLIC message counts for last 30 days ==="
    puts "Workspace:  id=#{workspace.id}, name=#{workspace.name.inspect}, slack_team_id=#{workspace.slack_team_id.inspect}"
    puts "Cutoff:     #{cutoff_time} (ts=#{cutoff_ts})"
    puts "------------------------------------------------------"

    # 1) Pick a token owner (any workspace_user with a slack_history_token)
    token_owner =
      if ENV['TOKEN_WORKSPACE_USER_ID']
        WorkspaceUser.find(ENV['TOKEN_WORKSPACE_USER_ID'])
      else
        WorkspaceUser
          .where(workspace_id: workspace.id)
          .where.not(slack_history_token: nil)
          .order(:id)
          .first
      end

    unless token_owner&.slack_history_token.present?
      abort "No workspace_user with slack_history_token found for workspace #{workspace.id}. " \
            "Set TOKEN_WORKSPACE_USER_ID=... if needed."
    end

    owner_label = token_owner.email.presence ||
                  token_owner.real_name.presence ||
                  token_owner.slack_user_id

    puts "Using slack_history_token from workspace_user ##{token_owner.id} (#{owner_label})"
    puts

    client = Slack::Web::Client.new(token: token_owner.slack_history_token)

    # 2) Fetch ALL PUBLIC channels visible to this token
    public_channels = []
    cursor = nil

    begin
      resp = client.users_conversations(
        types: 'public_channel',  # ONLY public channels
        limit: 1000,
        cursor: cursor
      )

      (resp['channels'] || resp['conversations'] || []).each do |conv|
        public_channels << conv
      end

      cursor = resp.dig('response_metadata', 'next_cursor')
    end while cursor.present? && !cursor.empty?

    total_convs = public_channels.size
    puts "Found #{total_convs} PUBLIC channels for this token."
    public_channels.each do |c|
      puts "  - ##{c['name']} (#{c['id']})"
    end
    puts "------------------------------------------------------"

    if total_convs.zero?
      puts "No public channels found. Exiting."
      next
    end

    # 3) For each public channel, walk full history (since cutoff) and count messages
    grand_total = 0

    public_channels.each_with_index do |conv, idx|
      conv_id   = conv['id']
      conv_name = conv['name'] || conv_id

      puts "[#{idx + 1}/#{total_convs}] ##{conv_name} (#{conv_id})"

      conv_count    = 0
      history_cursor = nil

      begin
        history_resp = client.conversations_history(
          channel: conv_id,
          limit: 1000,            # max page size
          cursor: history_cursor,
          oldest: cutoff_ts.to_s  # only messages >= this ts
        )

        msgs = history_resp['messages'] || []
        puts "  page: #{msgs.size} messages"

        msgs.each do |msg|
          ts = msg['ts']
          next unless ts

          # Belt-and-suspenders: filter by cutoff here too
          if ts.to_f >= cutoff_ts
            conv_count += 1
          end
        end

        history_cursor = history_resp.dig('response_metadata', 'next_cursor')
      rescue Slack::Web::Api::Errors::TooManyRequestsError => e
        retry_after = (e.response_headers['retry-after'] || 30).to_i
        puts "  RATE LIMITED on ##{conv_name}, sleeping #{retry_after}s..."
        sleep retry_after
        retry
      rescue Slack::Web::Api::Errors::SlackError => e
        puts "  ERROR conversations_history for ##{conv_name}: #{e.class} #{e.message}"
        break
      end while history_cursor.present? && !history_cursor.empty?

      grand_total += conv_count
      puts "  => #{conv_count} messages in last 30 days for ##{conv_name}"
      puts "------------------------------------------------------"
    end

    puts "================== SUMMARY =================="
    puts "Total messages in PUBLIC channels last 30 days: #{grand_total}"
    puts "Workspace id=#{workspace.id}, token_owner id=#{token_owner.id} (#{owner_label})"
    puts "============================================="
  end

end
