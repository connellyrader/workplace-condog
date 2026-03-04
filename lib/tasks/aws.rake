namespace :aws do
  require "timeout"
  LOCK_KEYS = {
    process_messages: 20_001,
    fetch_detections: 20_002
  }.freeze

  def with_global_lock(lock_key)
    conn = ActiveRecord::Base.connection
    got = conn.select_value("SELECT pg_try_advisory_lock(#{lock_key})")
    ok = ActiveModel::Type::Boolean.new.cast(got)
    return false unless ok

    begin
      yield
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{lock_key})")
    end
    true
  end

  def advisory_lock_holders(lock_key)
    ActiveRecord::Base.connection.exec_query(<<~SQL.squish)
      SELECT a.pid,
             a.usename,
             a.state,
             a.query,
             EXTRACT(EPOCH FROM (now() - a.query_start)) AS age_seconds
      FROM pg_locks l
      JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE l.locktype = 'advisory'
        AND l.classid = 0
        AND l.objid = #{lock_key}
    SQL
  rescue => e
    puts "[Lock] failed to inspect advisory lock: #{e.class}: #{e.message}"
    nil
  end

  def clear_stale_advisory_lock!(lock_key, max_age_s: 300)
    rows = advisory_lock_holders(lock_key)
    return false if rows.nil? || rows.empty?

    rows.each do |row|
      age = row["age_seconds"].to_f
      pid = row["pid"].to_i
      if age >= max_age_s
        puts "[Lock] terminating stale advisory lock holder pid=#{pid} age=#{age.round(1)}s"
        ActiveRecord::Base.connection.execute("SELECT pg_terminate_backend(#{pid})")
        return true
      end
    end

    puts "[Lock] advisory lock held by active session; oldest_age=#{rows.map { |r| r['age_seconds'].to_f }.max.round(1)}s"
    false
  end

  desc "Process unprocessed messages in batches. Usage: rake 'aws:process_messages[10]' (10 batches/run)."
  task :process_messages, [:batches] => :environment do |_, args|
    batches = (args[:batches] || ENV["PROCESS_BATCHES_PER_RUN"] || 5).to_i
    batch_size = ENV.fetch("INFERENCE_BATCH_SIZE", "100").to_i
    message_limit = [batches, 0].max * [batch_size, 1].max

    locked = with_global_lock(LOCK_KEYS[:process_messages]) do
      start = Time.current
      Rails.logger.info("[Cron] aws:process_messages start batches=#{batches} batch_size=#{batch_size} message_limit=#{message_limit}")
      puts "MessageProcessor: batches=#{batches} batch_size=#{batch_size} message_limit=#{message_limit}"
      n = Inference::MessageProcessor.call(limit: message_limit)
      puts "Done. Processed #{n}."
      elapsed = (Time.current - start).round(2)
      Rails.logger.info("[Cron] aws:process_messages done processed=#{n} elapsed_s=#{elapsed}")
    end

    puts "MessageProcessor: skipped (lock held)" unless locked
  end

  desc "Fetch detection output files from S3. Usage: rake 'aws:fetch_detections[10]' (10 files/run)."
  task :fetch_detections, [:file_limit] => :environment do |_, args|
    file_limit = (args[:file_limit] || ENV["FETCH_FILES_PER_RUN"] || 10).to_i

    fetch_timeout = (ENV["FETCH_DETECTIONS_TIMEOUT_SEC"] || "240").to_i
    lock_stale_after = (ENV["FETCH_DETECTIONS_LOCK_STALE_SEC"] || "600").to_i

    locked = with_global_lock(LOCK_KEYS[:fetch_detections]) do
      start = Time.current
      Rails.logger.info("[Cron] aws:fetch_detections start file_limit=#{file_limit} timeout=#{fetch_timeout}s")
      puts "DetectionFetcher: scanning outputs (file_limit=#{file_limit}, timeout=#{fetch_timeout}s)…"
      n = nil
      begin
        Timeout.timeout(fetch_timeout) do
          n = Inference::DetectionFetcher.call(limit: file_limit)
        end
        puts "Done. Processed #{n}."
      rescue Timeout::Error
        puts "[DetectionFetcher] timeout after #{fetch_timeout}s"
      end
      elapsed = (Time.current - start).round(2)
      Rails.logger.info("[Cron] aws:fetch_detections done processed=#{n} elapsed_s=#{elapsed}")
    end

    unless locked
      puts "DetectionFetcher: skipped (lock held)"
      if (rows = advisory_lock_holders(LOCK_KEYS[:fetch_detections])) && rows.any?
        oldest = rows.map { |r| r["age_seconds"].to_f }.max
        Rails.logger.warn("[DetectionFetcher] lock held age_seconds=#{oldest.round(1)} holders=#{rows.size}")
      end
      cleared = clear_stale_advisory_lock!(LOCK_KEYS[:fetch_detections], max_age_s: lock_stale_after)
      if cleared
        puts "[Lock] stale lock cleared; retrying fetch_detections once"
        locked = with_global_lock(LOCK_KEYS[:fetch_detections]) do
          puts "DetectionFetcher: scanning outputs (file_limit=#{file_limit}, timeout=#{fetch_timeout}s)…"
          n = nil
          begin
            Timeout.timeout(fetch_timeout) do
              n = Inference::DetectionFetcher.call(limit: file_limit)
            end
            puts "Done. Processed #{n}."
          rescue Timeout::Error
            puts "[DetectionFetcher] timeout after #{fetch_timeout}s"
          end
        end
        puts "DetectionFetcher: skipped (lock held)" unless locked
      end
    end
  end
end
