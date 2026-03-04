# lib/tasks/slack_sync.rake
require "timeout"

# Tiny PG advisory lock helper (scoped by job type + channel id)
module PgLease
  extend self
  KEYS = {
    backfill: 10_001,
    audit: 10_002,
    slack_backfill_tick: 10_011,
    teams_backfill_tick: 10_012
  }.freeze

  def try_lock(scope, channel_id)
    k1 = KEYS.fetch(scope)
    conn = ActiveRecord::Base.connection
    got  = conn.select_value("SELECT pg_try_advisory_lock(#{k1}, #{channel_id})")
    ActiveModel::Type::Boolean.new.cast(got)
  end

  def unlock(scope, channel_id)
    k1 = KEYS.fetch(scope)
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{k1}, #{channel_id})")
  end

  def with_lock(scope, channel_id)
    ok = try_lock(scope, channel_id)
    return false unless ok
    begin
      yield
    ensure
      unlock(scope, channel_id)
    end
    true
  end

  def locked_ids(scope)
    k1 = KEYS.fetch(scope)
    ActiveRecord::Base.connection.select_values(<<~SQL.squish).map!(&:to_i)
      SELECT objid
      FROM pg_locks
      WHERE locktype = 'advisory'
        AND classid = #{k1}
        AND objsubid = 2
        AND granted = true
    SQL
  end

  def with_global_lock(scope)
    k = KEYS.fetch(scope)
    conn = ActiveRecord::Base.connection
    got = conn.select_value("SELECT pg_try_advisory_lock(#{k})")
    ok = ActiveModel::Type::Boolean.new.cast(got)
    return false unless ok
    begin
      yield
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{k})")
    end
    true
  end
end

namespace :slack do
  # ---------- BACKFILL ----------
  namespace :backfill do
    DEFAULT_MAX_PER_TICK = 80
    DEFAULT_ERROR_RETRY_AFTER_MINUTES = 30
    DEEP_STAGE_MILESTONE_DAYS = [60, 90, 180].freeze
    DEEP_STAGE_INCREMENT_DAYS = 90

    def phase_a_pending_clause(seconds_30d:)
      [
        <<~SQL.squish,
          (
            channels.backfill_anchor_latest_ts IS NULL
            OR channels.backfill_next_oldest_ts IS NULL
            OR channels.backfill_next_oldest_ts > GREATEST(
              channels.backfill_anchor_latest_ts - :seconds_30d,
              COALESCE(channels.created_unix, 0)
            )
          )
        SQL
        { seconds_30d: seconds_30d }
      ]
    end

    def error_retry_cutoff
      mins = DEFAULT_ERROR_RETRY_AFTER_MINUTES
      mins = 0 if mins.negative?
      mins.minutes.ago
    end

    def apply_error_retry_cooldown(scope, retry_after:)
      scope.where(<<~SQL.squish, retry_after: retry_after)
        NOT (
          channels.last_history_status = 'error'
          AND COALESCE(channels.last_history_error, '') ILIKE 'No available Slack user token%'
        )
        AND
        channels.history_unreachable IS DISTINCT FROM TRUE
        AND (
          channels.last_history_status IS NULL
          OR (
            channels.last_history_status NOT IN ('error', 'unreachable', 'timeout')
            AND channels.last_history_status NOT LIKE 'unreachable%'
          )
          OR (
            (
              channels.last_history_status IN ('error', 'unreachable', 'timeout')
              OR channels.last_history_status LIKE 'unreachable%'
            )
            AND (channels.updated_at IS NULL OR channels.updated_at <= :retry_after)
          )
        )
      SQL
    end

    def phase_a_scope(base:, seconds_30d:, retry_after:)
      sql, binds = phase_a_pending_clause(seconds_30d: seconds_30d)
      apply_error_retry_cooldown(
        base.where(backfill_complete: false).where(sql, binds),
        retry_after: retry_after
      )
    end

    def covered_days_for(channel)
      anchor = channel.backfill_anchor_latest_ts.to_f
      cursor = (channel.backfill_next_oldest_ts || channel.backfill_anchor_latest_ts).to_f
      return 0 if anchor <= 0

      [((anchor - cursor) / 86_400.0).floor, 0].max
    end

    def next_deep_target_days(channel)
      covered = covered_days_for(channel)
      milestone = DEEP_STAGE_MILESTONE_DAYS.find { |days| covered < days }
      return milestone if milestone

      last = DEEP_STAGE_MILESTONE_DAYS.last
      last + (((covered - last) / DEEP_STAGE_INCREMENT_DAYS).floor + 1) * DEEP_STAGE_INCREMENT_DAYS
    end

    def claim_channels(scope:, max:, lock_scope:)
      return [] if max <= 0

      claimed_ids = []
      offset = 0
      slice_size = max

      loop do
        candidate_ids = scope.offset(offset).limit(slice_size).pluck(:id)
        break if candidate_ids.empty?

        candidate_ids.each do |id|
          next unless PgLease.try_lock(lock_scope, id)

          claimed_ids << id
          break if claimed_ids.size >= max
        end

        break if claimed_ids.size >= max
        offset += slice_size
      end

      return [] if claimed_ids.empty?

      by_id = Channel.where(id: claimed_ids).index_by(&:id)
      claimed_ids.filter_map { |id| by_id[id] }
    end

    def process_claimed_channels(channels:, lock_scope:)
      remaining = channels.map(&:id)

      channels.each do |ch|
        begin
          yield ch
        ensure
          PgLease.unlock(lock_scope, ch.id)
          remaining.delete(ch.id)
        end
      end
    ensure
      remaining.each { |id| PgLease.unlock(lock_scope, id) }
    end

    desc "Backfill tick: drain phase A first, then run phase B"
    task tick: :environment do
      run_tick = proc do
        max      = (ENV["BACKFILL_MAX_PER_TICK"] || DEFAULT_MAX_PER_TICK).to_i
        workspace_id = ENV["BACKFILL_WORKSPACE_ID"].presence

        base = Channel.joins(:integration)
                      .where(integrations: { kind: "slack" })
                      .where(is_archived: false)
                      .then { |rel| workspace_id ? rel.where(integrations: { workspace_id: workspace_id }) : rel }

        seconds_30d = 30.days.to_i
        retry_after = error_retry_cutoff
        phase_a_pending = phase_a_scope(base: base, seconds_30d: seconds_30d, retry_after: retry_after).exists?
        # Always drain phase A fully before any phase B work.
        run_phase_b = !phase_a_pending
        mode = run_phase_b ? :phase_b_deep : :phase_a_30d

        puts "[slack:backfill:tick] mode=#{mode} max=#{max} phase_a_pending=#{phase_a_pending} phase_a_drained=#{run_phase_b} retry_after_min=#{DEFAULT_ERROR_RETRY_AFTER_MINUTES}"

        if run_phase_b
          Rake::Task["slack:backfill:phase_b"].reenable
          Rake::Task["slack:backfill:phase_b"].invoke(workspace_id)
        else
          Rake::Task["slack:backfill:phase_a"].reenable
          Rake::Task["slack:backfill:phase_a"].invoke(workspace_id)
        end
      end

      run_tick.call
    end

    desc "Backfill phase A only: bring channels to 30-day ready"
    task :phase_a, %i[workspace_id] => :environment do |_t, args|
      max = (ENV["BACKFILL_MAX_PER_TICK"] || DEFAULT_MAX_PER_TICK).to_i
      workspace_id = args[:workspace_id].presence || ENV["BACKFILL_WORKSPACE_ID"].presence

      base = Channel.joins(integration: :workspace)
                    .where(integrations: { kind: "slack" })
                    .where(workspaces: { archived_at: nil })
                    .where(is_archived: false)
                    .then { |rel| workspace_id ? rel.where(integrations: { workspace_id: workspace_id }) : rel }

      seconds_30d = 30.days.to_i
      retry_after = error_retry_cutoff
      pending_scope = phase_a_scope(base: base, seconds_30d: seconds_30d, retry_after: retry_after)

      ordered_phase_a = pending_scope.order(Arel.sql("COALESCE(integrations.setup_completed_at, integrations.created_at) ASC, channels.created_at ASC, channels.id ASC"))
      channels = claim_channels(scope: ordered_phase_a, max: max, lock_scope: :backfill)
      puts "[slack:backfill:phase_a] channels=#{channels.size} paging=unbounded retry_after=#{retry_after.iso8601}"

      process_claimed_channels(channels: channels, lock_scope: :backfill) do |ch|
        begin
          Slack::HistoryIngestor.new(ch).backfill_30d_step!
        rescue => e
          Rails.logger.error "Backfill error (phase_a_30d) for channel #{ch.id} slack=#{ch.external_channel_id} name=#{ch.name.inspect}: #{e.class} #{e.message}"
        end
      end
    end

    desc "Backfill phase B only: deep history for channels already 30d-ready"
    task :phase_b, %i[workspace_id] => :environment do |_t, args|
      max = (ENV["BACKFILL_MAX_PER_TICK"] || DEFAULT_MAX_PER_TICK).to_i
      return if max <= 0

      workspace_id = args[:workspace_id].presence || ENV["BACKFILL_WORKSPACE_ID"].presence

      base = Channel.joins(integration: :workspace)
                    .where(integrations: { kind: "slack" })
                    .where(workspaces: { archived_at: nil })
                    .where(is_archived: false)
                    .then { |rel| workspace_id ? rel.where(integrations: { workspace_id: workspace_id }) : rel }

      seconds_30d = 30.days.to_i
      retry_after = error_retry_cutoff
      pending_phase_a_scope = phase_a_scope(base: base, seconds_30d: seconds_30d, retry_after: retry_after)

      phase_b_scope = apply_error_retry_cooldown(
                            base.where(backfill_complete: false).where.not(id: pending_phase_a_scope.select(:id)),
                            retry_after: retry_after
                          )
                          .order(Arel.sql("COALESCE(channels.backfill_anchor_latest_ts - channels.backfill_next_oldest_ts, 0) ASC, COALESCE(integrations.setup_completed_at, integrations.created_at) ASC, channels.created_at ASC, channels.id ASC"))

      channels = claim_channels(scope: phase_b_scope, max: max, lock_scope: :backfill)
      puts "[slack:backfill:phase_b] channels=#{channels.size} paging=wave_stages(60d,90d,6m,9m,+3m) retry_after=#{retry_after.iso8601}"

      process_claimed_channels(channels: channels, lock_scope: :backfill) do |ch|
        begin
          target_days = next_deep_target_days(ch)
          Slack::HistoryIngestor.new(ch).backfill_deep_step!(target_days: target_days)
        rescue => e
          Rails.logger.error "Backfill error (phase_b_deep) for channel #{ch.id} slack=#{ch.external_channel_id} name=#{ch.name.inspect}: #{e.class} #{e.message}"
        end
      end
    end
  end

  # ---------- FORWARD AUDIT ----------
  namespace :audit do
    desc "Run forward audits for stale channels (bounded by env AUDIT_MAX_PER_TICK)"
    task tick: :environment do
      max        = (ENV["AUDIT_MAX_PER_TICK"] || 100).to_i
      stale_after= (ENV["AUDIT_STALE_AFTER_MIN"] || 50).to_i.minutes
      timeoutS   = (ENV["AUDIT_STEP_TIMEOUT_SEC"] || 60).to_i

      scope = Channel
          .joins(integration: :workspace)
          .where(integrations: { kind: "slack" })
          .where(workspaces: { archived_at: nil })
          .joins(:channel_memberships)
          .where(channel_memberships: { left_at: nil })
          .distinct
          .where("last_audit_at IS NULL OR last_audit_at < ?", Time.current - stale_after)
          .order(Arel.sql("RANDOM()"))
          .limit(max)


      puts "[slack:audit:tick] auditing #{scope.size} channels..."
      scope.each do |ch|
        locked = PgLease.with_lock(:audit, ch.id) do
          begin
            Timeout.timeout(timeoutS) { Slack::HistoryIngestor.new(ch).forward_audit! }
            puts "  ✓ audit ok: channel=#{ch.id} #{ch.name || ch.external_channel_id}"
          rescue Timeout::Error
            Rails.logger.warn "Audit timeout for channel #{ch.id}"
          rescue => e
            Rails.logger.error "Audit error for channel #{ch.id}: #{e.class} #{e.message}"
          end
        end
        puts "  • skipped (locked): channel=#{ch.id}" unless locked
      end
    end
  end

  # ---------- DIRECTORY & MEMBERSHIPS ----------
  desc "Full re-sync of members/channels/memberships for all workspaces"
  task resync: :environment do
    Integration.joins(:workspace).where(kind: "slack").where(workspaces: { archived_at: nil }).find_each do |integration|
      begin
        Slack::IntegrationSetup.new(integration).run!
        puts "  ✓ integration synced: #{integration.id} #{integration.name}"
      rescue => e
        Rails.logger.error "Slack resync error for integration #{integration.id}: #{e.class} #{e.message}"
      end
    end
  end

  # Handy single-workspace sync: rake "slack:workspace:sync[123]"
  namespace :workspace do
    task :sync, [:id] => :environment do |_t, args|
      ws = Workspace.find(args[:id])
      ws.integrations.where(kind: "slack").find_each do |integration|
        Slack::IntegrationSetup.new(integration).run!
        puts "  ✓ workspace synced: #{ws.id} #{ws.name} (integration #{integration.id})"
      end
    end
  end
end
