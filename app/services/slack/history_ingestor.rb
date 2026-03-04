# app/services/slack/history_ingestor.rb

# Slack::HistoryIngestor is responsible for ingesting Slack channel history into the local `messages` table.
# It supports (A) a constrained 30-day backfill window (Slack API limitation), (B) a deeper backfill in
# additional windows down to the channel creation boundary, and (C) an ongoing forward audit that pulls
# the newest messages with overlap to avoid missing late-arriving events.
#
# This version intentionally skips messages that have no usable text payload (e.g., image/file-only posts)
# to reduce “dangling” rows that cannot be processed by downstream pipelines.

module Slack
  class HistoryIngestor
    PAGE = 200
    OVERLAP_SECONDS = 300

    def initialize(channel)
      @channel     = channel
      @integration = channel.integration
      @resolver    = Slack::UserResolver.new(@integration)
    end

    # ---------------------------
    # Phase A: pull most recent 30 days (cannot go deeper)
    # ---------------------------
    def backfill_30d_step!(max_pages: nil)
      Rails.logger.info "[Slack::HistoryIngestor] backfill_30d channel=#{@channel.id} ext=#{@channel.external_channel_id} cursor=#{@channel.backfill_next_oldest_ts}"

      init_bounds! if @channel.backfill_anchor_latest_ts.blank?

      anchor  = BigDecimal(@channel.backfill_anchor_latest_ts.to_s)
      cutoff  = cutoff_30d(anchor) # clamps to created_unix
      cursor  = current_cursor(anchor)

      # Already 30d-ready?
      return 0 if cursor.to_f <= cutoff.to_f

      attempts, new_cursor = process_slice!(oldest: cutoff, latest: cursor, max_pages: max_pages)

      if new_cursor.nil?
        # No messages exist in [cutoff..cursor] → we're done with Phase A for this channel.
        new_cursor = cutoff
        status = "empty_complete_30d"
      else
        status = "ok"
      end

      covered = days_covered(anchor, new_cursor)

      @channel.update!(
        backfill_next_oldest_ts: new_cursor,
        backfill_window_days: [covered, 30].max,
        last_history_status: status,
        last_history_error: nil,
        history_unreachable: false
      )

      Rails.logger.info "[Slack::HistoryIngestor] backfill_30d_done channel=#{@channel.id} attempts=#{attempts} next_oldest=#{new_cursor} status=#{status}"
      attempts
    rescue => e
      handle_history_failure(e)
    end

    # ---------------------------
    # Phase B: continue history in deep mode.
    # Optionally stop at a target coverage milestone (in days) to support
    # breadth-first "wave" progression across channels.
    # ---------------------------
    def backfill_deep_step!(max_pages: nil, target_days: nil)
      return 0 if @channel.backfill_complete?

      init_bounds! if @channel.backfill_anchor_latest_ts.blank?

      anchor   = BigDecimal(@channel.backfill_anchor_latest_ts.to_s)
      boundary = BigDecimal((@channel.created_unix || 0).to_s)
      cursor   = current_cursor(anchor)
      step_boundary = deep_step_boundary(anchor: anchor, created_boundary: boundary, target_days: target_days)

      # already complete?
      if cursor.to_f <= boundary.to_f
        @channel.update!(backfill_complete: true)
        return 0
      end

      # Already at/behind this step's target boundary.
      return 0 if cursor.to_f <= step_boundary.to_f

      attempts, new_cursor = process_slice!(oldest: step_boundary, latest: cursor, max_pages: max_pages)

      if new_cursor.nil?
        # No messages in [step_boundary..cursor] for this step.
        new_cursor = step_boundary
        status = step_boundary.to_f <= boundary.to_f ? "empty_complete_deep" : "ok"
      else
        status = "ok"
      end

      covered = days_covered(anchor, new_cursor)

      @channel.update!(
        backfill_next_oldest_ts: new_cursor,
        backfill_window_days: [covered, 30].max,
        last_history_status: status,
        last_history_error: nil,
        history_unreachable: false
      )

      @channel.update!(backfill_complete: true) if new_cursor.to_f <= boundary.to_f

      attempts
    rescue => e
      handle_history_failure(e)
    end

    def forward_audit!
      newest = @channel.forward_newest_ts || (ts_now_num - 3600)
      oldest = [newest - OVERLAP_SECONDS, 0].max
      process_range!(oldest: oldest, latest: ts_now_num).tap do
        @channel.update!(
          last_audit_at:        Time.current,
          last_history_status:  "ok",
          last_history_error:   nil,
          history_unreachable:  false
        )
      end
    end

    private

    def init_bounds!
      now = ts_now_num
      @channel.update!(
        backfill_anchor_latest_ts: now,  # fixed anchor
        backfill_next_oldest_ts:   now,  # cursor starts at anchor
        backfill_window_days:      30
      )
    end

    def current_cursor(anchor)
      c = @channel.backfill_next_oldest_ts.present? ? BigDecimal(@channel.backfill_next_oldest_ts.to_s) : anchor
      c = anchor if c > anchor
      c
    end

    def cutoff_30d(anchor)
      created_boundary = BigDecimal((@channel.created_unix || 0).to_s)
      cutoff = anchor - 30.days.to_i
      [cutoff, created_boundary].max
    end

    def deep_step_boundary(anchor:, created_boundary:, target_days:)
      td = target_days.to_i
      return created_boundary if td <= 0

      target_oldest = anchor - (td * 86_400)
      [target_oldest, created_boundary].max
    end

    # Time-based pagination (no Slack cursor token stored):
    # each call fetches newest page within [oldest..latest]
    # new_cursor becomes the oldest ts we saw - overlap
    def process_slice!(oldest:, latest:, max_pages: nil)
      iu, svc = Slack::TokenPool.new(integration: @integration).token_for_channel(channel: @channel)
      raise "No available Slack user token for channel #{@channel.external_channel_id}" unless svc
      channel_external_id = slack_external_channel_id_for(iu)
      raise "No slack channel id available for channel #{@channel.id}" if channel_external_id.blank?

      total_attempts = 0
      page = 0
      oldest_ts_seen = nil
      local_latest = latest
      page_limit = max_pages.nil? ? nil : max_pages.to_i
      page_limit = nil if page_limit&.<= 0

      while page_limit.nil? || page < page_limit
        page += 1

        resp = svc.conversations_history(
          channel:   channel_external_id,
          limit:     PAGE,
          oldest:    ts_to_s(oldest),
          latest:    ts_to_s(local_latest),
          inclusive: true
        )

        messages = resp.messages || []
        total_attempts += upsert_messages!(messages)

        break if messages.empty?

        # IMPORTANT:
        # Cursor advancement must be based on *all* messages returned by Slack, even if we skip some
        # for storage (e.g., file/image-only posts). Otherwise we can get stuck re-fetching the same page.
        min_ts = messages.map { |m| ts_to_num(m["ts"]) }.compact.min
        break unless min_ts

        oldest_ts_seen = min_ts if oldest_ts_seen.nil? || min_ts < oldest_ts_seen
        local_latest = min_ts - OVERLAP_SECONDS

        break if local_latest.to_f <= oldest.to_f
      end

      return [total_attempts, nil] unless oldest_ts_seen

      new_cursor = oldest_ts_seen - OVERLAP_SECONDS
      new_cursor = [new_cursor, oldest].max
      [total_attempts, new_cursor]
    end

    def process_range!(oldest:, latest:)
      iu, svc = Slack::TokenPool.new(integration: @integration).token_for_channel(channel: @channel)
      raise "No available Slack user token for channel #{@channel.external_channel_id}" unless svc
      channel_external_id = slack_external_channel_id_for(iu)
      raise "No slack channel id available for channel #{@channel.id}" if channel_external_id.blank?

      total_attempts = 0
      cursor = nil

      loop do
        resp = svc.conversations_history(
          channel:   channel_external_id,
          limit:     PAGE,
          cursor:    cursor,
          oldest:    ts_to_s(oldest),
          latest:    ts_to_s(latest),
          inclusive: true
        )
        total_attempts += upsert_messages!(resp.messages || [])
        cursor = resp.response_metadata&.next_cursor
        break if cursor.blank?
      end

      total_attempts
    end

    def upsert_messages!(messages)
      return 0 if messages.empty?

      now = Time.current
      scrubber = ::Messages::PiiScrubber.new

      skipped_short = 0

      normalized = messages.filter_map do |m|
        # --- Humans-only guards (Slack payload level) ---
        subtype = m["subtype"].to_s

        # bot_message subtype is the canonical Slack bot indicator
        next if subtype == "bot_message"

        # many bot/app messages have these present
        next if m["bot_id"].present? || m["bot_profile"].present?

        # if you truly want "humans only", require a Slack user id on the message
        next if m["user"].blank?

        # --- Existing "must have actionable text" rule ---
        raw_text = m["text"].to_s
        next if raw_text.strip.blank?
        text = scrubber.scrub(raw_text.strip)
        next if text.blank?

        if word_count(text) < 5
          skipped_short += 1
          next
        end

        iu = @resolver.resolve!(m)
        ts_num = ts_to_num(m["ts"])
        next unless iu && ts_num

        # --- Humans-only guard (domain level) ---
        next if iu.respond_to?(:is_bot) && iu.is_bot?

        # --- Translation: detect language and translate to English if needed ---
        translation = ::Messages::Translator.translate(text)

        {
          slack_ts: m["ts"],
          posted_at: Time.at(ts_num.to_f),
          text: translation[:text],
          text_original: translation[:text_original],
          original_language: translation[:original_language],
          subtype: raw_text,
          slack_user_id: iu.slack_user_id,
          display_name: iu.display_name,
          real_name: iu.real_name,
          email: iu.email,
          avatar_url: iu.avatar_url,
          title: iu.title
        }
      end

      if skipped_short.positive?
        Rails.logger.info("[Slack::HistoryIngestor] skipped_short_text_lt_5 channel=#{@channel.id} count=#{skipped_short}")
      end

      return 0 if normalized.empty?

      # Write source integration/channel first.
      source_rows = build_rows_for_channel(
        normalized: normalized,
        channel: @channel,
        integration: @integration
      )
      upsert_rows!(source_rows)
      update_forward_marker!(@channel, source_rows)

      # Secure fan-out: same Slack team + same external channel + same kind only.
      # This avoids duplicate API pulls across duplicate integration channels.
      fanout_total = fanout_to_duplicate_channels!(normalized)

      source_rows.size + fanout_total
    end


    def build_rows_for_channel(normalized:, channel:, integration:)
      return [] if normalized.blank?

      slack_uids = normalized.map { |n| n[:slack_user_id].to_s }.reject(&:blank?).uniq
      existing = integration.integration_users.where(slack_user_id: slack_uids).index_by(&:slack_user_id)

      rows = []
      normalized.each do |n|
        slack_uid = n[:slack_user_id].to_s
        next if slack_uid.blank?

        iu = existing[slack_uid]
        unless iu
          iu = integration.integration_users.find_or_initialize_by(slack_user_id: slack_uid)
          iu.display_name ||= n[:display_name]
          iu.real_name ||= n[:real_name]
          iu.email ||= n[:email]
          iu.avatar_url ||= n[:avatar_url]
          iu.title ||= n[:title] if iu.respond_to?(:title)
          iu.active = true if iu.respond_to?(:active) && iu.active.nil?
          iu.save!
          existing[slack_uid] = iu
        end

        next if iu.respond_to?(:is_bot) && iu.is_bot?

        rows << {
          integration_user_id: iu.id,
          integration_id: integration.id,
          channel_id: channel.id,
          slack_ts: n[:slack_ts],
          posted_at: n[:posted_at],
          text: n[:text],
          text_original: n[:text_original],
          original_language: n[:original_language],
          subtype: n[:subtype],
          processed: false,
          sent_for_inference_at: nil,
          processed_at: nil
        }
      end

      rows
    end

    def upsert_rows!(rows)
      return if rows.blank?

      Message.upsert_all(
        rows,
        unique_by: :index_messages_on_channel_id_and_slack_ts,
        update_only: %i[integration_user_id integration_id posted_at subtype]
      )
    end

    def update_forward_marker!(channel, rows)
      newest = rows.map { |r| BigDecimal(r[:slack_ts].to_s) rescue nil }.compact.max
      return unless newest

      if channel.forward_newest_ts.nil? || newest > channel.forward_newest_ts
        channel.update!(forward_newest_ts: newest)
      end
    end

    def fanout_to_duplicate_channels!(normalized)
      team_id = @integration.slack_team_id.to_s
      ext_id = @channel.external_channel_id.to_s
      return 0 if team_id.blank? || ext_id.blank?

      targets = Channel
        .joins(:integration)
        .where(integrations: { kind: "slack", slack_team_id: team_id })
        .where(external_channel_id: ext_id, kind: @channel.kind, is_archived: false)
        .where.not(id: @channel.id)

      written = 0
      targets.find_each do |target|
        # Security guard: only fan out into channels that have known membership rows.
        next unless ChannelMembership.where(channel_id: target.id).exists?

        rows = build_rows_for_channel(
          normalized: normalized,
          channel: target,
          integration: target.integration
        )
        next if rows.empty?

        upsert_rows!(rows)
        update_forward_marker!(target, rows)
        written += rows.size
      end

      if written.positive?
        Rails.logger.info("[Slack::HistoryIngestor] fanout channel=#{@channel.id} ext=#{ext_id} team=#{team_id} wrote=#{written}")
      end

      written
    end

    def slack_external_channel_id_for(iu)
      @channel.slack_external_id_for(integration_user: iu)
    rescue
      @channel.external_channel_id
    end

    def word_count(text)
      text.to_s.scan(/\b[\p{L}\p{N}'-]+\b/).size
    end

    def ts_now_num
      BigDecimal(Time.now.to_f.to_s)
    end

    def ts_to_num(ts)
      return nil if ts.blank?
      BigDecimal(ts.to_s)
    rescue
      BigDecimal(ts.to_f.to_s) rescue nil
    end

    def ts_to_s(num)
      return "0" if num.nil?
      num.is_a?(BigDecimal) ? num.to_s("F") : BigDecimal(num.to_s).to_s("F")
    rescue
      num.to_s
    end

    def days_covered(anchor, cursor)
      ((anchor.to_f - cursor.to_f) / 86_400.0).floor
    end

    def handle_history_failure(e)
      attrs = {
        last_history_status: "error",
        last_history_error:  e.message
      }

      if unreachable_channel_error?(e)
        attrs[:last_history_status] = "unreachable"
        attrs[:history_unreachable] = true
      end

      @channel.update!(attrs)
    rescue => update_err
      Rails.logger.warn("[Slack::HistoryIngestor] failed to record history error channel=#{@channel.id}: #{update_err.class} #{update_err.message}")
    ensure
      raise e
    end

    def unreachable_channel_error?(e)
      return true if defined?(Slack::Web::Api::Errors::NotInChannel) && e.is_a?(Slack::Web::Api::Errors::NotInChannel)
      return true if defined?(Slack::Web::Api::Errors::ChannelNotFound) && e.is_a?(Slack::Web::Api::Errors::ChannelNotFound)

      msg = e.message.to_s.downcase
      msg.include?("channel_not_found") ||
        msg.include?("not_in_channel") ||
        msg.include?("is_archived")
    end
  end
end
