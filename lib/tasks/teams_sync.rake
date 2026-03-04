# lib/tasks/teams_sync.rake
require "timeout"

# Reuse pg advisory locks if already loaded; otherwise define a minimal helper.
unless defined?(PgLease)
  module PgLease
    extend self
    KEYS = {
      backfill: 10_001,
      audit: 10_002,
      slack_backfill_tick: 10_011,
      teams_backfill_tick: 10_012
    }.freeze

    def with_lock(scope, channel_id)
      k1 = KEYS.fetch(scope)
      conn = ActiveRecord::Base.connection
      got  = conn.select_value("SELECT pg_try_advisory_lock(#{k1}, #{channel_id})")
      ok   = ActiveModel::Type::Boolean.new.cast(got)
      return false unless ok
      begin
        yield
      ensure
        conn.execute("SELECT pg_advisory_unlock(#{k1}, #{channel_id})")
      end
      true
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
end

namespace :teams do
  namespace :backfill do
    desc "Teams backfill tick: completes last 30d across all channels first, then continues deep history"
    task tick: :environment do
      locked = PgLease.with_global_lock(:teams_backfill_tick) do
        max      = (ENV["TEAMS_BACKFILL_MAX_PER_TICK"] || 80).to_i
        timeoutS = (ENV["TEAMS_BACKFILL_STEP_TIMEOUT_SEC"] || 120).to_i
        workers  = (ENV["TEAMS_BACKFILL_WORKERS"] || 4).to_i
        workers  = [[workers, 1].max, 8].min
        seconds_30d = 30.days.to_i

        base = Channel.joins(integration: :workspace)
                      .where(integrations: { kind: "microsoft_teams" })
                      .where(workspaces: { archived_at: nil })
                      .where(kind: %w[public_channel private_channel im mpim], is_archived: false)

        phase_a_scope = base.where(<<~SQL.squish, seconds_30d: seconds_30d)
          (
            backfill_anchor_latest_ts IS NULL
            OR backfill_next_oldest_ts IS NULL
            OR backfill_next_oldest_ts > (backfill_anchor_latest_ts - :seconds_30d)
          )
        SQL

        phase_a_remaining = phase_a_scope.exists?

        scope =
          if phase_a_remaining
            phase_a_scope.order(Arel.sql("RANDOM()")).limit(max)
          else
            base.where(backfill_complete: [false, nil]).order(Arel.sql("RANDOM()")).limit(max)
          end

        mode = phase_a_remaining ? :phase_a_30d : :phase_b_deep
        puts "[teams:backfill:tick] mode=#{mode} channels=#{scope.size}"

        if workers <= 1 || scope.size <= 1
          scope.each do |ch|
            channel_locked = PgLease.with_lock(:backfill, ch.id) do
              begin
                Timeout.timeout(timeoutS) do
                  Teams::HistorySyncService.new(ch.integration).backfill_channel_step!(ch, mode: mode)
                end
              rescue Timeout::Error
                Rails.logger.warn "Teams backfill timeout for channel #{ch.id}"
              rescue => e
                Rails.logger.error "Teams backfill error for channel #{ch.id}: #{e.class} #{e.message}"
              end
            end
            puts "  • skipped (locked): channel=#{ch.id}" unless channel_locked
          end
        else
          q = Queue.new
          scope.each { |ch| q << ch }

          threads = workers.times.map do
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                loop do
                  ch = q.pop(true) rescue nil
                  break unless ch
                  channel_locked = PgLease.with_lock(:backfill, ch.id) do
                    begin
                      Timeout.timeout(timeoutS) do
                        Teams::HistorySyncService.new(ch.integration).backfill_channel_step!(ch, mode: mode)
                      end
                    rescue Timeout::Error
                      Rails.logger.warn "Teams backfill timeout for channel #{ch.id}"
                    rescue => e
                      Rails.logger.error "Teams backfill error for channel #{ch.id}: #{e.class} #{e.message}"
                    end
                  end
                  puts "  • skipped (locked): channel=#{ch.id}" unless channel_locked
                end
              end
            end
          end

          threads.each(&:join)
        end
      end

      puts "[teams:backfill:tick] skipped (global lock held)" unless locked
    end
  end

  desc "Full re-sync of Teams directory/channels/memberships for all integrations"
  task resync: :environment do
    Integration.joins(:workspace).where(kind: "microsoft_teams").where(workspaces: { archived_at: nil }).find_each do |integration|
      begin
        Teams::IntegrationSetup.call(integration)
        puts "  ✓ teams integration synced: #{integration.id} #{integration.name}"
      rescue => e
        Rails.logger.error "Teams resync error for integration #{integration.id}: #{e.class} #{e.message}"
      end
    end
  end

  # ---------- FORWARD AUDIT ----------
  namespace :audit do
    desc "Run hybrid sync (per-integration backfill + tenant-level forward sync)"
    task tick: :environment do
      max_per_tick = (ENV["TEAMS_AUDIT_MAX_PER_TICK"] || 25).to_i
      stale_after_min = (ENV["TEAMS_AUDIT_STALE_AFTER_MIN"] || 60).to_i
      timeout_s = (ENV["TEAMS_AUDIT_STEP_TIMEOUT_SEC"] || 120).to_i

      puts "[teams:audit:tick] hybrid max_per_tick=#{max_per_tick} stale_after_min=#{stale_after_min} timeout_s=#{timeout_s}"

      begin
        Teams::HybridSyncStrategy.sync_all!(
          max_per_tick: max_per_tick,
          stale_after: stale_after_min.minutes,
          timeout_s: timeout_s
        )
        puts "  ✓ hybrid sync completed"
      rescue => e
        Rails.logger.error "Teams hybrid sync error: #{e.class} #{e.message}"
        puts "  ❌ hybrid sync failed: #{e.message}"
      end
    end
    
    desc "Run tenant-level forward sync only"
    task tenant_only: :environment do
      Teams::TenantSyncService.sync_all_tenants!
      puts "  ✓ tenant sync completed"
    end
    
    # Legacy integration-based sync (kept for debugging)
    desc "Run legacy per-integration forward audits"
    task legacy_tick: :environment do
      max         = (ENV["TEAMS_AUDIT_MAX_PER_TICK"] || 25).to_i
      stale_after = (ENV["TEAMS_AUDIT_STALE_AFTER_MIN"] || 60).to_i.minutes
      timeoutS    = (ENV["TEAMS_AUDIT_STEP_TIMEOUT_SEC"] || 120).to_i

      scope = Integration
                .joins(:workspace, :channels)
                .where(integrations: { kind: "microsoft_teams" })
                .where(workspaces: { archived_at: nil })
                .where(channels: { kind: %w[public_channel private_channel im mpim], is_archived: false })
                .where("channels.last_audit_at IS NULL OR channels.last_audit_at < ?", Time.current - stale_after)
                .distinct

      scope = Integration.from("(#{scope.to_sql}) integrations").order(Arel.sql("RANDOM()")).limit(max)

      puts "[teams:audit:legacy_tick] auditing #{scope.size} integrations..."

      scope.each do |integration|
        locked = PgLease.with_lock(:audit, integration.id) do
          begin
            Timeout.timeout(timeoutS) do
              Teams::HistorySyncService.new(integration).run_forward!
            end
            puts "  ✓ audit ok: integration=#{integration.id} #{integration.name}"
          rescue Timeout::Error
            Rails.logger.warn "Teams audit timeout for integration #{integration.id}"
          rescue => e
            Rails.logger.error "Teams audit error for integration #{integration.id}: #{e.class} #{e.message}"
          end
        end
        puts "  • skipped (locked): integration=#{integration.id}" unless locked
      end
    end
  end
end
