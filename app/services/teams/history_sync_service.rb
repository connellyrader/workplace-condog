# app/services/teams/history_sync_service.rb
module Teams
  class HistorySyncService
    GRAPH_BASE = "https://graph.microsoft.com/v1.0".freeze

    MAX_TEAM_MESSAGES_PER_RUN  = 5_000
    MAX_CHAT_MESSAGES_PER_USER = 5_000

    DEFAULT_BACKFILL_WINDOW_DAYS = 60
    MAX_BACKFILL_WINDOW_DAYS     = 365

    # Teams "full history" approximation boundary. Replace later if you store real channel created time.
    BACKFILL_COMPLETE_BOUNDARY = 5.years.ago.to_f

    TRANSIENT_HTTP_STATUSES = [500, 502, 503, 504].freeze
    MAX_HTTP_RETRIES        = 3

    PHASE_A_DAYS = 60

    def initialize(integration)
      @integration = integration
    end

    # ===========================
    # PUBLIC ENTRYPOINTS
    # ===========================

    # Single-channel step used by rake cron (phase A/B depending on caller)
    def backfill_channel_step!(channel, mode:)
      return 0 unless channel.integration_id == @integration.id
      return 0 if channel.is_archived?

      if chat_channel?(channel)
        iu = pick_available_iu_for_channel(channel)
        token = token_for(iu) if iu
        unless token
          Rails.logger.warn "[Teams::HistorySyncService] no token available for chat channel=#{channel.id} integration=#{@integration.id}"
          return 0
        end

        budget = if mode == :phase_a_30d
          (ENV["TEAMS_BACKFILL_PER_CHANNEL_BUDGET_PHASE_A"] || 200).to_i
        else
          (ENV["TEAMS_BACKFILL_PER_CHANNEL_BUDGET"] || 300).to_i
        end
        budget = 300 if budget <= 0

        return backfill_one_chat_channel(channel, token, budget, iu: iu, mode: mode)
      end

      team = channel.team
      unless team&.ms_team_id.present?
        Rails.logger.warn "[Teams::HistorySyncService] backfill skip channel=#{channel.id} missing team/ms_team_id"
        return 0
      end

      iu = pick_available_iu_for_channel(channel)
      token = token_for(iu) if iu
      unless token
        Rails.logger.warn "[Teams::HistorySyncService] no token available for channel=#{channel.id} integration=#{@integration.id}"
        return 0
      end

      budget = if mode == :phase_a_30d
        (ENV["TEAMS_BACKFILL_PER_CHANNEL_BUDGET_PHASE_A"] || 200).to_i
      else
        (ENV["TEAMS_BACKFILL_PER_CHANNEL_BUDGET"] || 300).to_i
      end
      budget = 300 if budget <= 0

      backfill_one_channel(team, channel, token, budget, iu: iu, mode: mode)
    end

    # Full history backfill, but prioritized:
    # 1) Phase A: get all channels to "30d ready"
    # 2) Phase B: continue deep backfill toward boundary
    def run_backfill!
      Rails.logger.info "[Teams::HistorySyncService] BACKFILL start integration=#{@integration.id} channels=#{@integration.channels.count} users=#{@integration.integration_users.where.not(ms_refresh_token: nil).count}"

      sync_team_channels_backfill(mode: :phase_a_30d)

      # Only proceed to deep mode when Phase A is complete across channels
      if phase_a_complete?
        sync_team_channels_backfill(mode: :phase_b_deep)
      end

      # Optional: chats in backfill mode (kept from your existing design)
      sync_chats_for_all_users(mode: :backfill)
    end

    # Forward mode: only newer messages since high-water marks
    def run_forward!
      Rails.logger.info "[Teams::HistorySyncService] FORWARD start integration=#{@integration.id} channels=#{@integration.channels.count} users=#{@integration.integration_users.where.not(ms_refresh_token: nil).count}"
      sync_team_channels_forward
      sync_chat_channels_forward
    end

    private

    # ===========================
    # 0) TOKEN SELECTION / RATE-LIMIT AWARE IU PICK
    # ===========================

    def pick_available_iu
      @integration.integration_users
                  .where.not(ms_refresh_token: nil)
                  .where("rate_limited_until IS NULL OR rate_limited_until < ?", Time.current)
                  .order(:id)
                  .first
    end

    # Prefer a token from a member of the target channel (required for private channels);
    # fall back to any available token so public channels don't stall.
    def pick_available_iu_for_channel(channel)
      member_iu =
        @integration.integration_users
                    .joins(:channel_memberships)
                    .where(channel_memberships: { channel_id: channel.id })
                    .where.not(ms_refresh_token: nil)
                    .where("rate_limited_until IS NULL OR rate_limited_until < ?", Time.current)
                    .order(:id)
                    .distinct
                    .first

      member_iu || pick_available_iu
    end

    def phase_a_complete?
      seconds_30d = PHASE_A_DAYS.days.to_i
      @integration.channels
                  .where(kind: "public_channel", is_archived: false, backfill_complete: [false, nil])
                  .where(history_unreachable: [false, nil])
                  .where(<<~SQL.squish, seconds_30d: seconds_30d)
                    (
                      backfill_anchor_latest_ts IS NULL
                      OR backfill_next_oldest_ts IS NULL
                      OR backfill_next_oldest_ts > (backfill_anchor_latest_ts - :seconds_30d)
                    )
                  SQL
                  .none?
    end

    # ===========================
    # 1) TEAM CHANNEL BACKFILL
    # ===========================

    def sync_team_channels_backfill(mode:)
      remaining_budget = MAX_TEAM_MESSAGES_PER_RUN
      seconds_30d = PHASE_A_DAYS.days.to_i

      scope = @integration.channels
                          .includes(:team)
                          .where(kind: %w[public_channel private_channel], is_archived: false, backfill_complete: [false, nil])
                          .where(history_unreachable: [false, nil])

      # Phase A: only channels not yet 30d-ready
      if mode == :phase_a_30d
        scope = scope.where(<<~SQL.squish, seconds_30d: seconds_30d)
          (
            backfill_anchor_latest_ts IS NULL
            OR backfill_next_oldest_ts IS NULL
            OR backfill_next_oldest_ts > (backfill_anchor_latest_ts - :seconds_30d)
          )
        SQL
      end

      # Fairness: random order so we don’t always deepen low IDs first
      scope = scope.order(Arel.sql("RANDOM()"))

      scope.find_each do |channel|
        break if remaining_budget <= 0

        team = channel.team
        unless team&.ms_team_id.present?
          Rails.logger.warn "[Teams::HistorySyncService] channel=#{channel.id} missing team/ms_team_id; skipping"
          next
        end

        iu = pick_available_iu_for_channel(channel)
        token = token_for(iu) if iu

        unless token
          Rails.logger.warn "[Teams::HistorySyncService] no token for channel=#{channel.id}; skipping backfill"
          next
        end

        per_channel_budget = [remaining_budget, 300].min
        consumed = backfill_one_channel(team, channel, token, per_channel_budget, iu: iu, mode: mode)
        remaining_budget -= consumed
      end
    end

    # mode:
    #  :phase_a_30d => clamp floor to anchor-30d (do not go deeper)
    #  :phase_b_deep => allow going deeper until boundary (full history)
    def backfill_one_channel(team, channel, token, budget, iu:, mode:)
      skipped_short = 0
      window_days = (channel.backfill_window_days.presence || DEFAULT_BACKFILL_WINDOW_DAYS).to_i
      window_days = window_days.clamp(1, MAX_BACKFILL_WINDOW_DAYS)

      now_ts = Time.current.to_f
      channel.update_columns(backfill_anchor_latest_ts: now_ts) if channel.backfill_anchor_latest_ts.nil?
      anchor_ts = channel.backfill_anchor_latest_ts || now_ts

      floor_ts =
        if mode == :phase_a_30d
          anchor_ts - PHASE_A_DAYS.days.to_i
        else
          BACKFILL_COMPLETE_BOUNDARY
        end

      window_end_ts = channel.backfill_next_oldest_ts.presence || anchor_ts
      window_end_ts = [window_end_ts.to_f, anchor_ts].min

      window_start_ts = window_end_ts - window_days.days
      window_start_ts = [window_start_ts, floor_ts].max

      processed     = 0
      earliest_seen = nil
      newest_seen   = nil

      url = "#{GRAPH_BASE}/teams/#{team.ms_team_id}/channels/#{channel.external_channel_id}/messages"

      loop do
        page = http_get(url, token, iu: iu, context: { channel: channel })
        break unless page && page["value"]

        messages = Array(page["value"])
        break if messages.empty?

        messages.each do |msg|
          created_at = parse_time(msg["createdDateTime"])
          next unless created_at
          ts = created_at.to_f

          next if ts > window_end_ts

          if ts < window_start_ts
            update_channel_backfill_pointers(channel, anchor_ts, earliest_seen, newest_seen)
            channel.update_columns(backfill_next_oldest_ts: window_start_ts)
            return processed
          end

          stored = upsert_message_from_ms(msg, channel)
          if stored
            sync_message_replies(team, channel, msg, token, iu: iu)
            processed += 1
            earliest_seen = created_at if earliest_seen.nil? || created_at < earliest_seen
            newest_seen   = created_at if newest_seen.nil?   || created_at > newest_seen
          elsif stored == :short_text
            skipped_short += 1
          end

          break if processed >= budget
        end

        break if processed >= budget

        next_link = page["@odata.nextLink"]
        break if next_link.blank?
        url = next_link
      end

      if processed.zero?
        # Still move pointer back so quiet channels don’t stall Phase A
        channel.update_columns(backfill_next_oldest_ts: window_start_ts)
      else
        update_channel_backfill_pointers(channel, anchor_ts, earliest_seen, newest_seen)
        channel.update_columns(backfill_next_oldest_ts: [channel.backfill_next_oldest_ts.to_f, window_start_ts].min)
      end

      if skipped_short.positive?
        Rails.logger.info("[Teams::HistorySyncService] skipped_short_text_lt_5 channel=#{channel.id} count=#{skipped_short} phase=#{mode}")
      end

      if mode == :phase_b_deep && channel.backfill_next_oldest_ts.to_f <= BACKFILL_COMPLETE_BOUNDARY
        channel.update_columns(backfill_complete: true)
      end

      processed
    end

    # Chat (IM/MPIM) backfill mirrors channel backfill but does not require a team.
    def backfill_one_chat_channel(channel, token, budget, iu:, mode:)
      skipped_short = 0
      window_days = (channel.backfill_window_days.presence || DEFAULT_BACKFILL_WINDOW_DAYS).to_i
      window_days = window_days.clamp(1, MAX_BACKFILL_WINDOW_DAYS)

      now_ts = Time.current.to_f
      channel.update_columns(backfill_anchor_latest_ts: now_ts) if channel.backfill_anchor_latest_ts.nil?
      anchor_ts = channel.backfill_anchor_latest_ts || now_ts

      floor_ts =
        if mode == :phase_a_30d
          anchor_ts - PHASE_A_DAYS.days.to_i
        else
          BACKFILL_COMPLETE_BOUNDARY
        end

      window_end_ts = channel.backfill_next_oldest_ts.presence || anchor_ts
      window_end_ts = [window_end_ts.to_f, anchor_ts].min

      window_start_ts = window_end_ts - window_days.days
      window_start_ts = [window_start_ts, floor_ts].max

      processed     = 0
      earliest_seen = nil
      newest_seen   = nil

      url = "#{GRAPH_BASE}/chats/#{channel.external_channel_id}/messages"

      loop do
        page = http_get(url, token, iu: iu, context: { channel: channel })
        break unless page && page["value"]

        messages = Array(page["value"])
        break if messages.empty?

        messages.each do |msg|
          created_at = parse_time(msg["createdDateTime"])
          next unless created_at
          ts = created_at.to_f

          next if ts > window_end_ts

          if ts < window_start_ts
            update_channel_backfill_pointers(channel, anchor_ts, earliest_seen, newest_seen)
            channel.update_columns(backfill_next_oldest_ts: window_start_ts)
            return processed
          end

          stored = upsert_message_from_ms(msg, channel)
          if stored
            processed += 1
            earliest_seen = created_at if earliest_seen.nil? || created_at < earliest_seen
            newest_seen   = created_at if newest_seen.nil?   || created_at > newest_seen
          elsif stored == :short_text
            skipped_short += 1
          end

          break if processed >= budget
        end

        break if processed >= budget

        next_link = page["@odata.nextLink"]
        break if next_link.blank?
        url = next_link
      end

      if processed.zero?
        channel.update_columns(backfill_next_oldest_ts: window_start_ts)
      else
        update_channel_backfill_pointers(channel, anchor_ts, earliest_seen, newest_seen)
        channel.update_columns(backfill_next_oldest_ts: [channel.backfill_next_oldest_ts.to_f, window_start_ts].min)
      end

      if skipped_short.positive?
        Rails.logger.info("[Teams::HistorySyncService] skipped_short_text_lt_5 channel=#{channel.id} count=#{skipped_short} phase=#{mode}")
      end

      if mode == :phase_b_deep && channel.backfill_next_oldest_ts.to_f <= BACKFILL_COMPLETE_BOUNDARY
        channel.update_columns(backfill_complete: true)
      end

      processed
    end

    def update_channel_backfill_pointers(channel, anchor_ts, earliest_seen, newest_seen)
      earliest_ts = earliest_seen&.to_f
      newest_ts   = newest_seen&.to_f

      attrs = { backfill_anchor_latest_ts: channel.backfill_anchor_latest_ts || anchor_ts }

      # overlap to avoid edge gaps
      attrs[:backfill_next_oldest_ts] = (earliest_ts - 300) if earliest_ts

      if newest_ts
        current_fwd = channel.forward_newest_ts || 0
        attrs[:forward_newest_ts] = [current_fwd, newest_ts].max
      end

      channel.update!(attrs)
    end

    def sync_message_replies(team, channel, parent_msg, token, iu:)
      parent_id = parent_msg["id"]
      url = "#{GRAPH_BASE}/teams/#{team.ms_team_id}/channels/#{channel.external_channel_id}/messages/#{parent_id}/replies"

      each_page(url, token, iu: iu, context: { channel: channel }) do |page|
        Array(page["value"]).each { |reply| upsert_message_from_ms(reply, channel) } # humans-only: may no-op
      end
    rescue => e
      Rails.logger.warn "[Teams::HistorySyncService] replies failed parent=#{parent_id} channel=#{channel.id}: #{e.class}: #{e.message}"
    end

    # ===========================
    # 2) TEAM CHANNEL FORWARD
    # ===========================

    def sync_team_channels_forward
      remaining_budget = MAX_TEAM_MESSAGES_PER_RUN
      audit_time       = Time.current

      @integration.channels
                  .includes(:team)
                  .where(kind: %w[public_channel private_channel], is_archived: false)
                  .find_each do |channel|
        break if remaining_budget <= 0

        team = channel.team
        next unless team&.ms_team_id.present?

        fwd_ts = channel.forward_newest_ts
        if fwd_ts.nil?
          channel.update_columns(forward_newest_ts: Time.current.to_f, last_audit_at: audit_time)
          next
        end

        newest_seen_ts = fwd_ts
        processed = 0

        iu = pick_available_iu_for_channel(channel)
        token = token_for(iu) if iu
        unless token
          Rails.logger.warn "[Teams::HistorySyncService] no token for channel=#{channel.id}; skipping forward sync"
          next
        end

        url = "#{GRAPH_BASE}/teams/#{team.ms_team_id}/channels/#{channel.external_channel_id}/messages"

        loop do
          page = http_get(url, token, iu: iu, context: { channel: channel })
          break unless page && page["value"]

          messages = Array(page["value"])
          break if messages.empty?

          stop = false
          messages.each do |msg|
            created_at = parse_time(msg["createdDateTime"])
            next unless created_at
            ts = created_at.to_f

            if ts <= fwd_ts
              stop = true
              break
            end

            stored = upsert_message_from_ms(msg, channel)
            if stored
              sync_message_replies(team, channel, msg, token, iu: iu)
              newest_seen_ts = [newest_seen_ts, ts].max
              processed += 1
              break if processed >= remaining_budget
            elsif stored == :short_text
              # no-op, but do not block forward cursors
            end
          end

          break if processed >= remaining_budget
          break if stop

          next_link = page["@odata.nextLink"]
          break if next_link.blank?
          url = next_link
        end

        remaining_budget -= processed
        updates = { last_audit_at: audit_time }
        updates[:forward_newest_ts] = newest_seen_ts if newest_seen_ts > fwd_ts
        channel.update_columns(updates)
      end
    end

    def sync_chat_channels_forward
      remaining_budget = MAX_CHAT_MESSAGES_PER_USER
      audit_time       = Time.current

      @integration.channels
                  .where(kind: %w[im mpim], is_archived: false)
                  .find_each do |channel|
        break if remaining_budget <= 0

        fwd_ts = channel.forward_newest_ts
        if fwd_ts.nil?
          channel.update_columns(forward_newest_ts: Time.current.to_f, last_audit_at: audit_time)
          next
        end

        newest_seen_ts = fwd_ts
        processed = 0

        iu = pick_available_iu_for_channel(channel)
        token = token_for(iu) if iu
        unless token
          Rails.logger.warn "[Teams::HistorySyncService] no token for chat channel=#{channel.id}; skipping forward sync"
          next
        end

        url = "#{GRAPH_BASE}/chats/#{channel.external_channel_id}/messages"

        loop do
          page = http_get(url, token, iu: iu, context: { channel: channel })
          break unless page && page["value"]

          values = Array(page["value"])
          break if values.empty?

          stop = false
          values.each do |msg|
            created_at = parse_time(msg["createdDateTime"])
            next unless created_at
            ts = created_at.to_f

            if ts <= fwd_ts
              stop = true
              break
            end

            stored = upsert_message_from_ms(msg, channel)
            if stored
              newest_seen_ts = [newest_seen_ts, ts].max
              processed += 1
              break if processed >= remaining_budget
            elsif stored == :short_text
              # no-op, but do not block forward cursors
            end
          end

          break if processed >= remaining_budget
          break if stop

          next_link = page["@odata.nextLink"]
          break if next_link.blank?
          url = next_link
        end

        remaining_budget -= processed
        updates = { last_audit_at: audit_time }
        updates[:forward_newest_ts] = newest_seen_ts if newest_seen_ts > fwd_ts
        channel.update_columns(updates)
      end
    end

    # ===========================
    # 3) CHATS (DMs/group chats)
    # ===========================

    def sync_chats_for_all_users(mode:)
      @integration.integration_users
                  .where.not(ms_refresh_token: nil)
                  .where("rate_limited_until IS NULL OR rate_limited_until < ?", Time.current)
                  .find_each { |iu| sync_for_user(iu, mode: mode) }
    end

    def sync_chats_for_subset(mode:, max_users:)
      return if max_users <= 0

      @integration.integration_users
                  .where.not(ms_refresh_token: nil)
                  .where("rate_limited_until IS NULL OR rate_limited_until < ?", Time.current)
                  .order(:id)
                  .limit(max_users)
                  .each { |iu| sync_for_user(iu, mode: mode) }
    end

    def sync_for_user(iu, mode:)
      token = token_for(iu)
      return unless token
      sync_chats_and_messages_for_user(iu, token, mode: mode)
    rescue => e
      Rails.logger.error "[Teams::HistorySyncService] chat sync failed iu=#{iu.id}: #{e.class}: #{e.message}"
    end

    def sync_chats_and_messages_for_user(iu, token, mode:)
      url = "#{GRAPH_BASE}/me/chats?$expand=members"
      processed = 0

      each_page(url, token, iu: iu) do |page|
        Array(page["value"]).each do |chat|
          break if processed >= MAX_CHAT_MESSAGES_PER_USER

          channel = upsert_channel_from_chat(chat, iu: iu)
          sync_chat_memberships(chat, channel)

          processed += sync_chat_messages(
            chat,
            channel,
            token,
            remaining_budget: MAX_CHAT_MESSAGES_PER_USER - processed,
            mode: mode,
            iu: iu
          )
        end
        break if processed >= MAX_CHAT_MESSAGES_PER_USER
      end
    end

    def upsert_channel_from_chat(chat, iu:)
      chat_id   = chat["id"]
      chat_type = chat["chatType"]
      topic     = chat["topic"].presence

      kind = (chat_type == "oneOnOne") ? "im" : "mpim"
      members = Array(chat["members"])

      name =
        if chat_type == "oneOnOne" && members.size == 2
          other = members.find do |m|
            member_user_id = m["userId"] || m.dig("user", "id") || m["id"]
            member_user_id.present? && member_user_id != iu.slack_user_id
          end
          topic || other&.dig("displayName") || "Direct message"
        else
          topic || "Group chat"
        end

      @integration.channels.find_or_initialize_by(external_channel_id: chat_id).tap do |ch|
        ch.kind        = kind
        ch.name        = name
        ch.is_private  = true
        ch.is_archived = false
        ch.save!
      end
    end

    def sync_chat_memberships(chat, channel)
      members = Array(chat["members"])
      members.each do |member|
        user_id = member["userId"] || member.dig("user", "id") || member["id"]
        next if user_id.blank?

        iu = @integration.integration_users.find_by(slack_user_id: user_id) ||
             @integration.integration_users.create!(
               slack_user_id: user_id,
               role: "member",
               is_bot: false,
               active: true
             )

        # Humans-only: do not attach memberships to bot/app IUs if any exist
        next if iu.respond_to?(:is_bot?) && iu.is_bot?

        ChannelMembership.find_or_create_by!(
          integration: @integration,
          channel: channel,
          integration_user: iu
        )
      end
    end

    def sync_chat_messages(chat, channel, token, remaining_budget:, mode:, iu:)
      return 0 if remaining_budget <= 0

      chat_id = chat["id"]
      processed = 0

      if mode == :forward
        fwd_ts = channel.forward_newest_ts
        if fwd_ts.nil?
          channel.update_columns(forward_newest_ts: Time.current.to_f)
          return 0
        end

        newest_seen_ts = fwd_ts
        url = "#{GRAPH_BASE}/chats/#{chat_id}/messages"

        loop do
          page = http_get(url, token, iu: iu, context: { channel: channel })
          break unless page && page["value"]

          values = Array(page["value"])
          break if values.empty?

          stop = false
          values.each do |msg|
            created_at = parse_time(msg["createdDateTime"])
            next unless created_at
            ts = created_at.to_f

            if ts <= fwd_ts
              stop = true
              break
            end

            stored = upsert_message_from_ms(msg, channel)
            if stored
              newest_seen_ts = [newest_seen_ts, ts].max
              processed += 1
              break if processed >= remaining_budget
            elsif stored == :short_text
              # no-op, but do not block forward cursors
            end
          end

          break if processed >= remaining_budget
          break if stop

          next_link = page["@odata.nextLink"]
          break if next_link.blank?
          url = next_link
        end

        channel.update_columns(forward_newest_ts: newest_seen_ts) if newest_seen_ts > fwd_ts
        return processed
      end

      url = "#{GRAPH_BASE}/chats/#{chat_id}/messages"
      newest_seen_ts = channel.forward_newest_ts || 0

      each_page(url, token, iu: iu, context: { channel: channel }) do |page|
        Array(page["value"]).each do |msg|
          break if processed >= remaining_budget

          created_at = parse_time(msg["createdDateTime"])
          ts = created_at&.to_f

          stored = upsert_message_from_ms(msg, channel)
          if stored
            newest_seen_ts = [newest_seen_ts, (ts || newest_seen_ts)].max
            processed += 1
          elsif stored == :short_text
            # no-op, but do not block forward cursors
          end
        end
        break if processed >= remaining_budget
      end

      channel.update_columns(forward_newest_ts: newest_seen_ts) if newest_seen_ts > (channel.forward_newest_ts || 0)
      processed
    end

    # Returns true if stored, :short_text if skipped for min-word guard, false otherwise.
    def upsert_message_from_ms(msg, channel)
      ms_message_id = msg["id"]
      body_html     = msg.dig("body", "content").to_s
      created_at    = parse_time(msg["createdDateTime"])

      clean_text = strip_html(body_html).to_s
      scrubbed_text = Messages::PiiScrubber.scrub(clean_text).strip
      return false if scrubbed_text.blank?

      return :short_text if word_count(scrubbed_text) < 5

      # ===========================
      # HUMANS-ONLY ENFORCEMENT
      # ===========================
      # Graph message "from" can be user/application/device/etc.
      # If you want humans-only, require a real user sender.
      from_user_id = msg.dig("from", "user", "id").to_s
      return false if from_user_id.blank?

      iu = @integration.integration_users.find_by(slack_user_id: from_user_id) ||
           @integration.integration_users.create!(
             slack_user_id: from_user_id,
             role: "member",
             is_bot: false,
             active: true
           )

      return false if iu.respond_to?(:is_bot?) && iu.is_bot?

      # --- Translation: detect language and translate to English if needed ---
      translation = ::Messages::Translator.translate(scrubbed_text)

      m = @integration.messages.find_or_initialize_by(slack_ts: ms_message_id)
      m.integration        = @integration
      m.channel            = channel
      m.integration_user   = iu
      m.text               = translation[:text]           # Always English
      m.text_original      = translation[:text_original]  # Original if non-English, nil otherwise
      m.original_language  = translation[:original_language]
      m.posted_at          = created_at

      parent_id = msg["replyToId"]
      m.slack_thread_ts = parent_id if parent_id.present?

      m.save!
      true
    end

    def word_count(text)
      text.to_s.scan(/\b[\p{L}\p{N}'-]+\b/).size
    end

    # ===========================
    # Token + HTTP helpers
    # ===========================

    def token_for(iu)
      if iu.ms_expires_at.present? && iu.ms_expires_at > 5.minutes.from_now
        iu.ms_access_token
      else
        refresh_ms_token_for(iu)
      end
    rescue => e
      Rails.logger.error "[Teams::HistorySyncService] token_for failed iu=#{iu.id}: #{e.class}: #{e.message}"
      nil
    end

    def refresh_ms_token_for(iu)
      raise "No ms_refresh_token for integration_user #{iu.id}" if iu.ms_refresh_token.blank?

      uri  = URI(Integration::MS_TOKEN_URL)
      body = {
        client_id:     ENV.fetch("TEAMS_CLIENT_ID"),
        client_secret: ENV.fetch("TEAMS_CLIENT_SECRET"),
        grant_type:    "refresh_token",
        refresh_token: iu.ms_refresh_token
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Rails.env.development?

      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(body)

      res  = http.request(req)
      data = JSON.parse(res.body) rescue {}

      return nil unless res.is_a?(Net::HTTPSuccess) && data["access_token"].present?

      iu.update!(
        ms_access_token:  data["access_token"],
        ms_refresh_token: data["refresh_token"].presence || iu.ms_refresh_token,
        ms_expires_at:    Time.current + data["expires_in"].to_i.seconds
      )

      iu.ms_access_token
    end

    def each_page(url, token, iu:, context: nil)
      loop do
        resp = http_get(url, token, iu: iu, context: context)
        break unless resp && resp["value"]

        yield resp

        next_link = resp["@odata.nextLink"]
        break if next_link.blank?
        url = next_link
      end
    end

    def http_get(url, token, iu:, context: nil)
      tries = 0
      channel = context && context[:channel]

      loop do
        tries += 1

        res =
          begin
            http_conn.get(url) do |req|
              req.headers["Authorization"] = "Bearer #{token}"
              req.headers["Accept"]        = "application/json"
            end
          rescue Faraday::TimeoutError, Faraday::ConnectionFailed
            if tries < MAX_HTTP_RETRIES
              sleep 2**(tries - 1)
              next
            end
            return nil
          end

        if res.status.between?(200, 299)
          begin
            channel&.mark_history_ok!
          rescue => e
            Rails.logger.warn("[Teams::HistorySyncService] failed to mark history ok channel=#{channel&.id}: #{e.class} #{e.message}")
          end
          return res.body
        end

        if res.status.in?([401, 403])
          err_msg =
            if res.body.is_a?(Hash)
              res.body.dig("error", "message") || res.body["message"]
            else
              res.body.to_s
            end

          Rails.logger.warn(
            "[Teams::HistorySyncService] HTTP #{res.status} channel=#{channel&.id} " \
            "iu=#{iu&.id} integration=#{@integration.id} url=#{url} error=#{err_msg}"
          )
          begin
            channel&.mark_history_error!(
              "teams http #{res.status}: #{err_msg}",
              unreachable: channel_unreachable_status?(res.status)
            )
          rescue => e
            Rails.logger.warn("[Teams::HistorySyncService] failed to mark history error channel=#{channel&.id}: #{e.class} #{e.message}")
          end
          return nil
        end

        if res.status.in?([404, 410])
          err_msg =
            if res.body.is_a?(Hash)
              res.body.dig("error", "message") || res.body["message"]
            else
              res.body.to_s
            end

          Rails.logger.warn(
            "[Teams::HistorySyncService] HTTP #{res.status} channel=#{channel&.id} " \
            "iu=#{iu&.id} integration=#{@integration.id} url=#{url} error=#{err_msg}"
          )

          begin
            channel&.mark_history_error!("teams http #{res.status}: #{err_msg}", unreachable: true)
          rescue => e
            Rails.logger.warn("[Teams::HistorySyncService] failed to mark history error channel=#{channel&.id}: #{e.class} #{e.message}")
          end
          return nil
        end

        if res.status == 429
          retry_after = res.headers["retry-after"].to_i
          retry_after = 60 if retry_after <= 0

          cid = context && context[:channel] ? context[:channel].id : nil
          Rails.logger.warn "[Teams::HistorySyncService] 429 rate_limited iu=#{iu&.id} channel=#{cid} retry_after=#{retry_after}s"
          iu&.update_columns(
            rate_limited_until: Time.current + retry_after.seconds,
            rate_limit_last_retry_after_seconds: retry_after
          )
          return nil
        end

        if TRANSIENT_HTTP_STATUSES.include?(res.status) && tries < MAX_HTTP_RETRIES
          sleep 2**(tries - 1)
          next
        end

        return nil
      end
    end

    def channel_unreachable_status?(status)
      status.to_i == 403
    end

    def http_conn
      @http_conn ||= Faraday.new do |f|
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end
    end

    def parse_time(str)
      return nil if str.blank?
      Time.parse(str) rescue nil
    end

    def strip_html(html)
      ActionView::Base.full_sanitizer.sanitize(html)
    end

    def chat_channel?(channel)
      channel.kind.in?(%w[im mpim])
    end
  end
end
