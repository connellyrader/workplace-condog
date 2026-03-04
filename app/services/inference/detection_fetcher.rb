# app/services/inference/detection_fetcher.rb
#
# Fetches completed async inference outputs from S3, converts them into Detection rows,
# marks AsyncInferenceResult + Message terminal, and advances Integration.days_analyzed / analyze_complete.
#
# Key reliability changes:
# - Sweeps very old "pending" AIRs to "failed" so a small tail of missing outputs cannot hang onboarding.
# - Excludes known unprocessable payloads (messages.text contains `"p":""`) from "pending" readiness checks
#   so image/file-only rows never block days_analyzed.
#
# Note: output prefix is derived from the active ModelTest's model
# (prefers model.sagemaker_model_name, then model.endpoint_name).

require "json"
require "zlib"
require "stringio"
require "set"

module Inference
  class DetectionFetcher
    AWS_REGION    = "us-east-2"
    OUTPUT_BUCKET = "workplace-io-processing"

    DEFAULT_LIMIT = 400

    # Conservative: if an async inference is still pending after this, treat as failed.
    STALE_PENDING_MINUTES = 120

    # Persist detections only when margin meets minimum threshold.
    # Keep this broad (default 0.0) so scoring policy can be tuned later without rerunning inference.
    # Margin is defined as: logit_score - polarity_threshold.
    MIN_LOGIT_MARGIN_TO_SAVE = ENV.fetch("DETECTION_SAVE_MIN_MARGIN", "0.0").to_f

    # Rollups are keyed by a minimum margin threshold (same global threshold for now).
    ROLLUP_LOGIT_MARGIN_MIN = ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f

    def self.call(limit: DEFAULT_LIMIT) = new.call(limit: limit)

    def initialize
      creds = Aws::Credentials.new(
        ENV.fetch("AWS_ACCESS_KEY_ID"),
        ENV.fetch("AWS_SECRET_ACCESS_KEY")
      )

      @s3 = Aws::S3::Client.new(region: AWS_REGION, credentials: creds)

      @active_model_test = ModelTest.active_for_inference
      raise "No active model test configured for detection fetcher" unless @active_model_test

      @active_model = @active_model_test.model
      raise "Active model test #{@active_model_test.id} has no model" unless @active_model

      model_folder = @active_model.sagemaker_model_name.presence || @active_model.endpoint_name.presence
      raise "Active model #{@active_model.id} missing sagemaker_model_name/endpoint_name" if model_folder.blank?
      @output_prefix = "async-results/#{model_folder}/"

      @sc_cache     = {}
      @subcat_cache = {}
      @name_map     = nil
      @subcat_map   = nil
      @cache_mutex  = Mutex.new
    end

    def call(limit:)
      sweep_stale_pending!

      keys = pick_oldest_keys(limit.to_i)
      processed = 0

      # Warm lookup maps before threading
      signal_category_name_map
      signal_subcategory_name_map

      workers = (ENV["FETCH_DETECTIONS_WORKERS"] || "4").to_i
      workers = [[workers, 1].max, 8].min

      if workers <= 1 || keys.size <= 1
        keys.each { |key| processed += 1 if process_key(key) }
      else
        q = Queue.new
        keys.each { |k| q << k }
        mutex = Mutex.new

        threads = workers.times.map do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              loop do
                key = q.pop(true) rescue nil
                break unless key
                begin
                  ok = process_key(key)
                  mutex.synchronize { processed += 1 } if ok
                rescue => e
                  Rails.logger.error("[DetectionFetcher] thread error: #{e.class}: #{e.message}")
                end
              end
            end
          end
        end

        threads.each(&:join)
      end

      Rails.logger.info("[DetectionFetcher] processed #{processed}/#{keys.size} (bucket=#{OUTPUT_BUCKET} prefix=#{@output_prefix})")
      processed
    end

    def process_key(key)
      s3_uri = "s3://#{OUTPUT_BUCKET}/#{key}"

      airs = AsyncInferenceResult.where(response_location: s3_uri, inference_type: "scoring").order(:id).to_a
      if airs.empty?
        Rails.logger.warn("[DetectionFetcher] Orphan output (no AIR): #{s3_uri}")
        safe_delete_object(key)
        return false
      end

      json = get_json(key)
      rows = normalize_payload_rows(json)
      unless rows.is_a?(Array)
        Rails.logger.error("[DetectionFetcher] Unexpected JSON for #{s3_uri}: #{json.class}")
        return false
      end

      matched = resolve_rows_to_airs!(s3_uri: s3_uri, airs: airs, rows: rows)
      return false unless matched

      pending = matched.select { |air, _| air.status == "pending" }
      bulk_results = bulk_upsert_detections_for_file!(pending)

      now = Time.current
      message_ids = pending.map { |air, _| air.message_id }.compact
      integrations = {}

      pending.each do |air, _|
        air.update!(status: "completed", completed_at: now)
        if (msg = air.message) && msg.integration
          integrations[msg.integration_id] = msg.integration
        end
      end

      if message_ids.any?
        Messages::PurgeService.purge_messages_batch(message_ids)
        Message.where(id: message_ids).update_all(
          processed:    true,
          processed_at: now,
          updated_at:   now
        )
      end

      integrations.values.each do |integration|
        advance_integration_progress!(integration)
      end

      if bulk_results
        bulk_results.each do |air_id, stats|
          Rails.logger.info("[DetectionFetcher] AIR #{air_id}: upserted #{stats[:created]} detections (skipped_margin<#{MIN_LOGIT_MARGIN_TO_SAVE}: #{stats[:skipped_margin]})")
        end
      end

      if airs.all? { |a| a.status != "pending" }
        safe_delete_object(key)
      else
        Rails.logger.warn("[DetectionFetcher] keeping output with pending AIRs: #{s3_uri}")
      end

      pending.any?
    rescue => e
      Rails.logger.error("[DetectionFetcher] #{s3_uri} failed: #{e.class}: #{e.message}")
      false
    end

    private

    # ------------------------------------------------------------
    # S3 helpers
    # ------------------------------------------------------------
    def pick_oldest_keys(limit)
      got = []
      token = nil

      while got.size < limit
        resp = @s3.list_objects_v2(
          bucket: OUTPUT_BUCKET,
          prefix: @output_prefix,
          continuation_token: token
        )

        resp.contents.sort_by(&:last_modified).each do |obj|
          got << obj.key
          break if got.size >= limit
        end

        break unless resp.is_truncated && got.size < limit
        token = resp.next_continuation_token
      end

      got
    end

    def get_json(key)
      resp = @s3.get_object(bucket: OUTPUT_BUCKET, key: key)
      body = resp.body.read

      if resp.content_encoding.to_s.downcase.include?("gzip")
        body = Zlib::GzipReader.new(StringIO.new(body)).read
      end

      JSON.parse(body)
    end

    def safe_delete_object(key)
      @s3.delete_object(bucket: OUTPUT_BUCKET, key: key)
    rescue => e
      Rails.logger.warn("[DetectionFetcher] delete failed s3://#{OUTPUT_BUCKET}/#{key}: #{e.class} #{e.message}")
    end

    # Normalize provider output into row hashes:
    # [{ air_id: Integer|nil, scores: [{label,logit}...] }, ...]
    def normalize_payload_rows(json)
      return nil unless json.is_a?(Array)

      # Legacy single-row payload: [{label,logit}...]
      if json.all? { |x| x.is_a?(Hash) && x.key?("label") && x.key?("logit") }
        return [{ air_id: nil, scores: json }]
      end

      # Legacy batched positional payload: [[{label,logit}...], ...]
      if json.all? { |x| x.is_a?(Array) }
        return json.map { |scores| { air_id: nil, scores: scores } }
      end

      # Safer ID-based payload: [{id, scores:[{label,logit}...]}...]
      if json.all? { |x| x.is_a?(Hash) && x.key?("id") && x.key?("scores") }
        return json.map do |row|
          { air_id: row["id"].to_i, scores: row["scores"] }
        end
      end

      nil
    end

    def resolve_rows_to_airs!(s3_uri:, airs:, rows:)
      by_id = airs.index_by(&:id)
      all_rows_have_ids = rows.all? { |r| r[:air_id].present? }

      if all_rows_have_ids
        resolved = rows.map do |row|
          air = by_id[row[:air_id]]
          unless air
            Rails.logger.error("[DetectionFetcher] AIR id #{row[:air_id]} not found for #{s3_uri}")
            return nil
          end
          [air, row[:scores]]
        end
        return resolved
      end

      # Positional fallback for backward compatibility.
      if rows.size != airs.size
        Rails.logger.error("[DetectionFetcher] row/AIR size mismatch for #{s3_uri}: rows=#{rows.size} airs=#{airs.size}")
        return nil
      end

      airs.zip(rows.map { |r| r[:scores] })
    end

    # ------------------------------------------------------------
    # Reliability sweep: pending that never completes
    # ------------------------------------------------------------
    def sweep_stale_pending!
      mins = STALE_PENDING_MINUTES.to_i
      return if mins <= 0

      cutoff = mins.minutes.ago

      stale =
        AsyncInferenceResult
          .where(status: "pending", inference_type: "scoring")
          .where("created_at < ?", cutoff)
          .limit(2_000)

      return if stale.none?

      now     = Time.current
      air_ids = stale.pluck(:id)
      msg_ids = stale.pluck(:message_id).compact

      AsyncInferenceResult.where(id: air_ids).update_all(status: "failed", completed_at: now)
      Message.where(id: msg_ids).update_all(processed: true, processed_at: now)

      Rails.logger.warn("[DetectionFetcher] swept stale pending AIRs count=#{air_ids.size} cutoff=#{cutoff.iso8601}")
    rescue => e
      Rails.logger.warn("[DetectionFetcher] sweep_stale_pending failed: #{e.class} #{e.message}")
      nil
    end

    # ------------------------------------------------------------
    # Integration progress: days_analyzed + analyze_complete
    # ------------------------------------------------------------
    def advance_integration_progress!(integration)
      # Canonical "pending" set for readiness:
      # - processed_at IS NULL means not terminal
      # - EXCLUDE blank payload messages (`"p":""`) so image/file-only rows do not block readiness
      pending_scope =
        Message
          .where(integration_id: integration.id, processed_at: nil)
          .where.not(posted_at: nil)
          .where.not(text: [nil, ""])
          .where.not("messages.text LIKE '%\"p\":\"\"%'")
          .where("length(btrim(messages.text)) > 0")

      attrs = {}
      new_days_analyzed = integration.days_analyzed.to_i

      if (newest_pending_at = pending_scope.maximum(:posted_at))
        candidate_days = (Time.current.to_date - newest_pending_at.to_date).to_i
        candidate_days = [candidate_days - 1, 0].max
        new_days_analyzed = [new_days_analyzed, candidate_days].max
      else
        earliest_msg_at =
          Message
            .where(integration_id: integration.id)
            .where("posted_at IS NOT NULL")
            .minimum(:posted_at)

        if earliest_msg_at
          candidate_days = (Time.current.to_date - earliest_msg_at.to_date).to_i + 1
          new_days_analyzed = [new_days_analyzed, candidate_days].max
        end

        # Mark analyze_complete only when:
        # - no pending inference messages remain, AND
        # - all channels have completed the 30-day backfill window
        seconds_60d = 60.days.to_i
        if Channel
             .where(integration_id: integration.id, is_archived: false, history_unreachable: false)
             .where.not(name: nil)  # exclude ghost channels
             .where(<<~SQL.squish, seconds_60d: seconds_60d)
               (
                 backfill_anchor_latest_ts IS NULL
                 OR backfill_next_oldest_ts IS NULL
                 OR backfill_next_oldest_ts > GREATEST(
                   backfill_anchor_latest_ts - :seconds_60d,
                   COALESCE(created_unix, 0)
                 )
               )
             SQL
             .none?
          attrs[:analyze_complete] = true
        end
      end

      attrs[:days_analyzed] = new_days_analyzed
      return if attrs.empty?

      ready_before = DashboardReadiness.ready?(workspace_id: integration.workspace_id)

      integration.update!(attrs)
      notify_dashboard_ready_if_needed(integration, ready_before: ready_before)
    rescue => e
      Rails.logger.warn("[DetectionFetcher] advance_integration_progress failed integration_id=#{integration.id}: #{e.class} #{e.message}")
      nil
    end

    # ------------------------------------------------------------
    # Detection upsert
    # ------------------------------------------------------------
    def bulk_upsert_detections_for_file!(pending)
      return {} if pending.empty?

      now = Time.current
      rows_to_insert = []
      rollup_candidates = {} # key => {metric_id, submetric_id, sc_id, polarity, posted_on, integration_user_id, workspace_id}
      per_air_stats = Hash.new { |h, k| h[k] = { created: 0, skipped_margin: 0 } }
      key_to_air = {}

      pending.each do |air, label_logits|
        model_test_id = air.model_test_id
        message_id    = air.message_id
        message       = air.message

        workspace_id = message&.integration&.workspace_id
        posted_on = message&.posted_at&.to_date
        integration_user_id = message&.integration_user_id

        label_logits.each do |obj|
          label = obj["label"].to_s
          logit = obj["logit"].to_f
          next if label.blank?

          sc_id = resolve_signal_category_id_from_label(label)
          next unless sc_id

          polarity = label =~ /_Positive\z/i ? "positive" : "negative"
          score    = polarity == "positive" ? 100 : 0

          sc           = fetch_sc(sc_id)
          submetric_id = sc.submetric_id
          metric_id    = sc.submetric&.metric_id

          subcat_id = resolve_signal_subcategory_id_from_label(label, expected_sc_id: sc_id)

          thr = (polarity == "positive" ? sc.positive_threshold : sc.negative_threshold)

          margin =
            begin
              t = Float(thr)
              logit - t
            rescue
              nil
            end

          if margin.nil? || margin < MIN_LOGIT_MARGIN_TO_SAVE
            per_air_stats[air.id][:skipped_margin] += 1
            next
          end

          rows_to_insert << {
            message_id:             message_id,
            signal_category_id:     sc_id,
            model_test_id:          model_test_id,
            polarity:               polarity,
            async_inference_result_id: air.id,
            full_output:            obj,
            score:                  score,
            logit_score:            logit,
            logit_margin:           margin,
            metric_id:              metric_id,
            submetric_id:           submetric_id,
            signal_subcategory_id:  subcat_id,
            created_at:             now,
            updated_at:             now
          }

          key = [message_id, sc_id, model_test_id, polarity]
          key_to_air[key] = air.id
          rollup_candidates[key] = {
            metric_id: metric_id,
            submetric_id: submetric_id,
            sc_id: sc_id,
            polarity: polarity,
            posted_on: posted_on,
            integration_user_id: integration_user_id,
            workspace_id: workspace_id
          }
        end
      end

      return per_air_stats if rows_to_insert.empty?

      result = Detection.insert_all(
        rows_to_insert,
        unique_by: :index_detections_on_msg_sc_mt_polarity,
        returning: %w[message_id signal_category_id model_test_id polarity]
      )

      inserted_keys = if result&.rows&.any?
        result.rows.map { |r| [r[0], r[1], r[2], r[3]] }.to_set
      else
        Set.new
      end

      rollup_by_ws = Hash.new { |h, k| h[k] = [] }

      inserted_keys.each do |key|
        air_id = key_to_air[key]
        per_air_stats[air_id][:created] += 1 if air_id

        meta = rollup_candidates[key]
        next unless meta && meta[:metric_id] && meta[:workspace_id] && meta[:posted_on]

        ws_id = meta[:workspace_id]

        rollup_by_ws[ws_id] << {
          posted_on: meta[:posted_on],
          dimension_type: "metric",
          dimension_id: meta[:metric_id],
          metric_id: meta[:metric_id],
          polarity: meta[:polarity],
          integration_user_id: meta[:integration_user_id]
        }

        if meta[:submetric_id]
          rollup_by_ws[ws_id] << {
            posted_on: meta[:posted_on],
            dimension_type: "submetric",
            dimension_id: meta[:submetric_id],
            metric_id: meta[:metric_id],
            polarity: meta[:polarity],
            integration_user_id: meta[:integration_user_id]
          }
        end

        rollup_by_ws[ws_id] << {
          posted_on: meta[:posted_on],
          dimension_type: "category",
          dimension_id: meta[:sc_id],
          metric_id: meta[:metric_id],
          polarity: meta[:polarity],
          integration_user_id: meta[:integration_user_id]
        }
      end

      rollup_by_ws.each do |ws_id, rollup_data|
        update_rollups!(workspace_id: ws_id, detections_data: rollup_data)
      end

      per_air_stats
    end

    # Update rollup tables with new detection counts (workspace + group level)
    def update_rollups!(workspace_id:, detections_data:)
      # Workspace-level rollups
      InsightDetectionRollup.bulk_increment_for_detections!(
        workspace_id: workspace_id,
        detections_data: detections_data,
        logit_margin_min: ROLLUP_LOGIT_MARGIN_MIN
      )

      # Group-level rollups (for fast compare_groups / group_gaps queries)
      InsightDetectionRollup.bulk_increment_for_groups!(
        workspace_id: workspace_id,
        detections_data: detections_data,
        logit_margin_min: ROLLUP_LOGIT_MARGIN_MIN
      )
    rescue => e
      Rails.logger.warn("[DetectionFetcher] rollup update failed: #{e.class} #{e.message}")
    end

    def notify_dashboard_ready_if_needed(integration, ready_before:)
      workspace = integration.workspace
      return unless workspace
      return if ready_before
      return unless DashboardReadiness.ready?(workspace_id: workspace.id)

      Notifiers::DashboardReadyNotifier.call(workspace: workspace)
    rescue => e
      Rails.logger.warn("[DetectionFetcher] dashboard_ready_notify_failed workspace_id=#{integration.workspace_id}: #{e.class}: #{e.message}")
      nil
    end

    # ------------------------------------------------------------
    # Cache helpers (thread-safe)
    # ------------------------------------------------------------
    def fetch_sc(sc_id)
      @cache_mutex.synchronize do
        @sc_cache[sc_id] ||= SignalCategory.find(sc_id)
      end
    end

    def fetch_subcat(subcat_id)
      @cache_mutex.synchronize do
        @subcat_cache[subcat_id] ||= SignalSubcategory.find(subcat_id)
      end
    end

    # ------------------------------------------------------------
    # Mapping helpers
    # ------------------------------------------------------------
    def resolve_signal_category_id_from_label(label)
      base = label.sub(/_(Positive|Negative)\z/i, "")
      norm = normalize_name(base)
      signal_category_name_map[norm]
    end

    def resolve_signal_subcategory_id_from_label(label, expected_sc_id:)
      base = label.sub(/_(Positive|Negative)\z/i, "")
      norm = normalize_name(base)
      sid  = signal_subcategory_name_map[norm]
      return nil unless sid

      sub = fetch_subcat(sid)
      sub.signal_category_id == expected_sc_id ? sid : nil
    end

    def signal_category_name_map
      @name_map ||= SignalCategory.all.each_with_object({}) do |sc, h|
        h[normalize_name(sc.name)] = sc.id
      end
    end

    def signal_subcategory_name_map
      @subcat_map ||= SignalSubcategory.all.each_with_object({}) do |sub, h|
        h[normalize_name(sub.name)] = sub.id
      end
    end

    def normalize_name(str)
      str.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end
  end
end
