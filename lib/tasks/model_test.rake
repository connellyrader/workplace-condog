require 'csv'
require 'aws-sdk-sagemakerruntime'
require "tiktoken_ruby"
require "ostruct"

namespace :model_test do
  ENCODER = Tiktoken.encoding_for_model("gpt-4")
  AWS_REGION = ENV.fetch("AWS_REGION", "us-east-2")
  AWS_BUCKET = ENV.fetch("SAGEMAKER_INPUT_BUCKET", "workplace-io-processing")

  # --- real-time output ---
  $stdout.sync = true
  $stderr.sync = true

  # make Rails logger flush immediately
  begin
    if (dev = Rails.logger&.instance_variable_get(:@logdev)) && dev.respond_to?(:dev)
      dev.dev.sync = true if dev.dev.respond_to?(:sync=)
    end
  rescue StandardError
  end

  desc "Preview context for a message"
  task preview_context: :environment do
    model_test = ModelTest.find(1)
    context = model_test.generate_context_for_message(Message.find(91))
    # puts context
    # puts "Token estimate: #{count_tokens(context)}"
  end

  desc "Test a singular message"
  task basic_test: :environment do
    model_test = ModelTest.find(17)
    workspace = model_test.workspace
    endpoint_name = model_test.model.endpoint_name

    previous_message_count = 5

    puts "starting"

    workspace.messages.where(:id => [60..102]).order(:posted_at).find_each do |message|
      context = model_test.generate_context_for_message(message)

      resp = invoke_async_endpoint(endpoint_name, context)
      unless resp
        Rails.logger.warn("Async invoke failed for message #{message.id}")
        next
      end

      if resp
        AsyncInferenceResult.create!(
          model_test:        model_test,
          message:           message,
          response_location: resp[:output_location],
          inference_arn:     resp[:inference_arn],
          status:            "pending",
          input_tokens:      count_tokens(context),
          inference_type:    "scoring"
        )
      end

      puts "Token estimate: #{count_tokens(context)} - Msg: #{message.id}"
    end
  end


  desc "Review detections for quality"
  task basic_review_test: :environment do
    total = 0
    ModelTest.where(id: [1]).order(id: :asc).find_each do |model_test|
      endpoint_name      = model_test.model.endpoint_name

      count = 0
      ModelTestDetection.where(model_test: model_test, async_inference_result_id: [50748, 50746, 50743, 50742, 50739, 50736, 50735, 50734, 50732, 50729, 50728, 50718, 50717, 50715, 50712, 50709]).includes(:message).limit(40).find_each do |det|
        begin
          context = model_test.generate_context_for_review(
            det.message,
            detection: det
          )

          resp = invoke_async_endpoint(
            endpoint_name,
            context,
            prefix: "review-inputs",
            key_suffix: "mt#{model_test.id}-det#{det.id}"
          )

          if resp
            AsyncInferenceResult.create!(
              model_test:        model_test,
              message:           det.message,
              response_location: resp.output_location,
              inference_arn:     resp.inference_arn,
              status:            "pending",
              input_tokens:      count_tokens(context),
              inference_type:    "review",
              model_test_detection_id: det.id
            )
          end

          count  += 1
          total  += 1
          puts "MT: #{model_test.id}, queued #{count} detection reviews..." if (count % 25).zero?
        rescue => e
          puts "Error queueing review for detection #{det.id}: #{e.message}"
          Rails.logger.error("Detection #{det.id} review invoke failed: #{e.message}")
          next
        end
      end
    end
    puts "Finished. Total review invocations: #{total}"
  end


  # --- REAL-TIME single test (sync InvokeEndpoint) ---
  # Usage examples:
  #   MT=98 rake model_test:rt_basic_test
  #   MT=98 MSG=1234 rake model_test:rt_basic_test
  #   MT=98 TEXT="hello world" rake model_test:rt_basic_test
  desc "Real-time single test (ENV: MT=<model_test_id> MSG=<message_id> or TEXT='...')"
  task rt_basic_test: :environment do
    mt_id = (ENV["MT"] || ENV["MODEL_TEST_ID"] || 1).to_i
    model_test = ModelTest.find(mt_id)
    model       = model_test.model
    endpoint    = model.endpoint_name.to_s

    if endpoint.blank?
      puts "ERROR: ModelTest #{mt_id} has no deployed endpoint_name."
      next
    end

    text = ENV["TEXT"]
    message =
      if ENV["MSG"]
        Message.find_by(id: ENV["MSG"].to_i)
      else
        model_test.workspace.messages.order(:posted_at).first
      end

    unless message || text
      puts "ERROR: No message found and TEXT not provided."
      next
    end

    payload_text = text.presence || message.text
    body_json    = { inputs: payload_text }.to_json

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp_body = invoke_realtime_endpoint(endpoint, body_json)
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    if resp_body.nil?
      puts "ERROR: Real-time invoke failed (see logs)."
      next
    end

    puts "=== Real-time Inference ==="
    puts "Endpoint:         #{endpoint}"
    puts "Input tokens:     #{count_tokens(payload_text)}"
    puts "Latency:          #{((t1 - t0) * 1000).round(1)} ms"
    puts "Raw response:\n#{resp_body}"

    # Insert metrics/submetrics/categories depending on availability
    created = insert_scores_to_detections!(resp_body, model_test, (message || OpenStruct.new(text: payload_text)), nil)
    puts "Inserted/updated #{created} detections for ModelTest #{model_test.id}."
  end


  # --- NEW: Enqueue async requests for the new "scores" format ---
  # Usage:
  #   MT=18 rake model_test:async_nlp_test
  #   MT=18 LIMIT=200 rake model_test:async_nlp_test
  #   MT=18 MSG=1234 rake model_test:async_nlp_test
  #   MT=18 SINCE=2025-09-01 rake model_test:async_nlp_test
  desc "Enqueue async invocations (new 'scores' format) for a model test"
  task async_nlp_test: :environment do
    mt_id = (ENV["MT"] || ENV["MODEL_TEST_ID"]).to_i
    raise "Set MT=<model_test_id>" if mt_id <= 0

    model_test = ModelTest.find(mt_id)
    model      = model_test.model
    endpoint   = model.endpoint_name.to_s
    raise "ModelTest #{mt_id} has no deployed endpoint_name" if endpoint.blank?

    limit = (ENV["LIMIT"] || 500).to_i
    since = ENV["SINCE"] ? Time.zone.parse(ENV["SINCE"]) : nil

    scope =
      if ENV["MSG"]
        Message.where(id: ENV["MSG"].to_i)
      else
        s = model_test.workspace.messages.order(:posted_at)
        s = s.where("posted_at >= ?", since) if since
        s.limit(limit)
      end

    enqueued = 0
    scope.find_each do |message|
      begin
        already = AsyncInferenceResult.where(model_test_id: mt_id, message_id: message.id, inference_type: "scoring")
                                      .where(status: %w[pending completed])
                                      .exists?
        next if already

        payload_text = message.text #model_test.generate_context_for_message(message) 
        body_json    = { inputs: [payload_text] }.to_json
        key_suffix   = "mt#{mt_id}-msg#{message.id}"

        resp = invoke_async_endpoint(endpoint, body_json, prefix: "rt-inputs", key_suffix: key_suffix)
        unless resp
          Rails.logger.warn("Async invoke failed for message #{message.id}")
          next
        end

        AsyncInferenceResult.create!(
          model_test:        model_test,
          message:           message,
          response_location: resp.output_location,
          inference_arn:     resp.inference_arn,
          status:            "pending",
          input_tokens:      count_tokens(payload_text),
          inference_type:    "scoring"
        )
        enqueued += 1
        puts "Enqueued msg=#{message.id} -> #{resp.output_location}"
      rescue => e
        Rails.logger.error("enqueue_rt_scores failed for msg=#{message.id}: #{e.class} #{e.message}")
        next
      end
    end

    puts "Done. Enqueued #{enqueued} async requests for ModelTest #{mt_id}."
  end


  desc "Enqueue async invocations (scores) v3 — instrumented; use MT, LIMIT, WORKSPACE_ID, SINCE, UNTIL, CHANNEL_ID, UNPROCESSED=1, DRY_RUN=1"
  task async_nlp_test_v3: :environment do
    mt_id = (ENV["MT"] || ENV["MODEL_TEST_ID"]).to_i
    raise "Set MT=<model_test_id>" if mt_id <= 0

    model_test = ModelTest.find(mt_id)
    model      = model_test.model
    endpoint   = model.endpoint_name.to_s
    raise "ModelTest #{mt_id} has no deployed endpoint_name" if endpoint.blank?

    # --- filters ---
    limit        = (ENV["LIMIT"] || 500).to_i; limit = 500 if limit <= 0
    ws_id        = (ENV["WORKSPACE_ID"] || model_test.workspace_id).to_i
    raise "workspace_id missing" if ws_id <= 0
    since_time   = ENV["SINCE"] ? Time.zone.parse(ENV["SINCE"]) : nil
    until_time   = ENV["UNTIL"] ? Time.zone.parse(ENV["UNTIL"]) : nil
    channel_id   = ENV["CHANNEL_ID"]&.to_i
    only_unproc  = ENV["UNPROCESSED"].to_s == "1"
    dry_run      = ENV["DRY_RUN"].to_s == "1"

    rel = Message.where(workspace_id: ws_id)
    rel = rel.where(channel_id: channel_id) if channel_id&.positive?
    rel = rel.where("posted_at >= ?", since_time) if since_time
    rel = rel.where("posted_at <= ?", until_time) if until_time
    rel = rel.where(processed: false) if only_unproc
    rel = rel.order(:id)

    candidate_ids = rel.limit(limit).pluck(:id)
    puts "MT=#{mt_id} ws_id=#{ws_id} candidates=#{candidate_ids.size} limit=#{limit} " \
          "since=#{since_time&.iso8601 || '-'} until=#{until_time&.iso8601 || '-'} " \
          "channel_id=#{channel_id || '-'} unprocessed=#{only_unproc} dry_run=#{dry_run}"

    if candidate_ids.empty?
      puts "No messages matched. Check filters or confirm messages exist in workspace #{ws_id}."
      next
    end

    # --- counters for instrumentation ---
    enqueued = 0
    skipped_dup  = 0
    skipped_ctx  = 0
    skipped_inv  = 0
    errors       = 0

    Message.where(id: candidate_ids).find_each do |message|
      begin
        # duplicate guard
        already = AsyncInferenceResult.where(
                    model_test_id: mt_id,
                    message_id:    message.id,
                    inference_type: "scoring"
                  ).where(status: %w[pending completed]).exists?
        if already
          skipped_dup += 1
          next
        end

        payload_text = message.text #model_test.generate_context_for_message(message) 
        body_json    = { inputs: [payload_text] }.to_json
        key_suffix   = "mt#{mt_id}-msg#{message.id}"


        if dry_run
          # In dry-run, just report we'd enqueue
          enqueued += 1
          next
        end


        resp = invoke_async_endpoint(endpoint, body_json, prefix: "rt-inputs", key_suffix: key_suffix)
        unless resp
          Rails.logger.warn("[async_nlp_test_v3] invoke failed msg=#{message.id}")
          skipped_inv += 1
          next
        end

        AsyncInferenceResult.create!(
          model_test:        model_test,
          message:           message,
          response_location: resp.output_location,
          inference_arn:     resp.inference_arn,
          status:            "pending",
          input_tokens:      count_tokens(payload_text),
          inference_type:    "scoring"
        )
        enqueued += 1
        puts "Enqueued msg=#{message.id} -> #{resp.output_location}"
      rescue => e
        errors += 1
        Rails.logger.error("[async_nlp_test_v3] msg=#{message.id} ERROR: #{e.class} #{e.message}")
        next
      end
    end

    puts "Summary: enqueued=#{enqueued} dup=#{skipped_dup} ctx_err=#{skipped_ctx} invoke_fail=#{skipped_inv} errors=#{errors}"
    puts "Done. Enqueued #{enqueued} async requests for ModelTest #{mt_id}."
  end
  


  # --- NEW: Fetch async results (scores) and insert metrics/submetrics/categories ---
  # Usage:
  #   MT=18 rake model_test:fetch_nlp_results
  #   MT=18 BATCH=100 rake model_test:fetch_nlp_results
  desc "Fetch async results (new 'scores' format) and insert metrics/submetrics/categories"
  task fetch_nlp_results: :environment do
    s3 = Aws::S3::Client.new(region: AWS_REGION)
    mt_id = (ENV["MT"] || ENV["MODEL_TEST_ID"]).to_i
    limit = (ENV["BATCH"] || 200).to_i

    scope = AsyncInferenceResult
              .where(status: "pending", inference_type: "scoring")
              .order(:created_at)
    scope = scope.where(model_test_id: mt_id) if mt_id.positive?
    scope = scope.limit(limit)

    count_done = 0
    count_total = 0

    scope.find_each do |air|
      count_total += 1
      begin
        m = air.response_location&.match(%r{\As3://([^/]+)/(.+)\z}i)
        unless m
          Rails.logger.warn("Bad output_location: #{air.response_location.inspect} for AIR #{air.id}")
          next
        end
        bucket, key = m[1], m[2]

        head = begin
          s3.head_object(bucket: bucket, key: key)
        rescue Aws::S3::Errors::NotFound
          puts "Result not ready yet for key: #{key}"
          next
        end

        body = begin
          s3.get_object(bucket: bucket, key: key).body.read
        rescue Aws::S3::Errors::NotFound
          puts "Result body not ready yet for key: #{key}"
          next
        end

        # Insert detections with logits (async path has AIR)
        msg = air.message || OpenStruct.new(text: nil)
        created = insert_scores_to_detections!(body, air.model_test, msg, air)

        completed_at = head.last_modified
        air.update!(
          status: "completed",
          duration: (completed_at - air.created_at).to_f,
          output_tokens: 0,
          completed_at: completed_at
        )
        count_done += 1
        
        puts "AIR #{air.id}: detections=#{created}"
      rescue => e
        Rails.logger.error("fetch_nlp_results failed for AIR #{air.id}: #{e.class} #{e.message}")
        next
      end
    end

    puts "Finished. Processed=#{count_total}, completed=#{count_done}."
  end


  desc "Fetch async S3 outputs via DetectionFetcher and upsert detections (ENV: LIMIT/BATCH, AWS_REGION, OUTPUT_BUCKET, OUTPUT_PREFIX, DELETE_ORPHANS=1|0)"
  task fetch_async_results_v2: :environment do
    # limit = LIMIT or BATCH or DetectionFetcher::DEFAULT_LIMIT
    limit = (ENV["LIMIT"] || ENV["BATCH"] || DetectionFetcher::DEFAULT_LIMIT).to_i
    limit = DetectionFetcher::DEFAULT_LIMIT if limit <= 0

    # Build a subclass to override constants from ENV (no changes to your service file needed)
    FetcherClass = Class.new(DetectionFetcher) do
      AWS_REGION     = ENV["AWS_REGION"]     || DetectionFetcher::AWS_REGION
      OUTPUT_BUCKET  = ENV["OUTPUT_BUCKET"]  || DetectionFetcher::OUTPUT_BUCKET
      OUTPUT_PREFIX  = ENV["OUTPUT_PREFIX"]  || DetectionFetcher::OUTPUT_PREFIX
      DELETE_ORPHANS = if ENV.key?("DELETE_ORPHANS")
                         ENV["DELETE_ORPHANS"].to_s == "1"
                       else
                         DetectionFetcher::DELETE_ORPHANS
                       end
    end

    started = Time.now
    Rails.logger.info("[detections:fetch_async_results_v2] start limit=#{limit} bucket=#{FetcherClass::OUTPUT_BUCKET} prefix=#{FetcherClass::OUTPUT_PREFIX} delete_orphans=#{FetcherClass::DELETE_ORPHANS}")

    processed = FetcherClass.call(limit: limit)

    elapsed = (Time.now - started).round(2)
    puts "✅ DetectionFetcher processed=#{processed} (limit=#{limit}) in #{elapsed}s"
    Rails.logger.info("[detections:fetch_async_results_v2] done processed=#{processed} elapsed=#{elapsed}s")
  rescue => e
    Rails.logger.error("[detections:fetch_async_results_v2] #{e.class}: #{e.message}")
    raise
  end


  # --- legacy async result fetchers (unchanged below) ---

  desc "Import signal data from CSV"
  task import_signals: :environment do
    file_path = 'lib/assets/signal_import1.csv'

    CSV.foreach(file_path, headers: true) do |row|
      metric = Metric.find_or_create_by!(name: row['Metric'])
      submetric = Submetric.find_or_create_by!(metric: metric, name: row['Sub-Metric'])
      signal_category = SignalCategory.find_or_create_by!(submetric: submetric, name: row['Signal Category'])
      signal_subcategory = SignalSubcategory.find_or_create_by!(signal_category: signal_category, name: row['Signal'])

      # if row['Positive Indicator'].present?
      #   SignalIndicator.find_or_create_by!(signal_subcategory: signal_subcategory, text: row['Positive Indicator'], indicator_type: 'positive')
      # end

      # if row['Negative Indicator'].present?
      #   SignalIndicator.find_or_create_by!(signal_subcategory: signal_subcategory, text: row['Negative Indicator'], indicator_type: 'negative')
      # end
    end

    puts "Import complete!"
  end

  desc "Run model test asynchronously"
  task run_test: :environment do
    total_count = 0
    ModelTest.where(:id => [16]).order(id: :asc).each do |model_test|
      workspace = model_test.workspace
      endpoint_name = model_test.model.endpoint_name

      count = 0
      puts "starting"
      workspace.messages.order(posted_at: :asc).find_each do |message|
        begin
          context = model_test.generate_context_for_message(message)
          resp    = invoke_async_endpoint(endpoint_name, context)

          if resp
            AsyncInferenceResult.create!(
              model_test:        model_test,
              message:           message,
              response_location: resp.output_location,
              inference_arn:     resp.inference_arn,
              status:            "pending",
              input_tokens:      count_tokens(context),
              inference_type:    "scoring"
            )
          end

          count += 1
          total_count += 1
          puts "MT: #{model_test.id}, Invoked #{count} messages..." if count % 25 == 0
        rescue => e
          puts "Error processing message #{message.id}: #{e.message}"
          Rails.logger.error("Message #{message.id} failed during async invoke: #{e.message}")
          next
        end
      end
    end

    puts "Finished. Total invocations: #{total_count}"
  end

  desc "Review detections for quality"
  task run_detection_review: :environment do
    total = 0
    ModelTest.where(id: [3]).order(id: :asc).find_each do |model_test|
      endpoint_name      = model_test.model.endpoint_name

      count = 0
      ModelTestDetection.where(model_test: model_test, ai_quality_score: nil).includes(:message).find_each do |det|
        begin
          context = model_test.generate_context_for_review(
            det.message,
            detection: det
          )

          resp = invoke_async_endpoint(
            endpoint_name,
            context,
            prefix: "review-inputs",
            key_suffix: "mt#{model_test.id}-det#{det.id}"
          )

          if resp
            AsyncInferenceResult.create!(
              model_test:        model_test,
              message:           det.message,
              response_location: resp.output_location,
              inference_arn:     resp.inference_arn,
              status:            "pending",
              input_tokens:      count_tokens(context),
              inference_type:    "review",
              model_test_detection_id: det.id
            )
          end

          count  += 1
          total  += 1
          puts "MT: #{model_test.id}, queued #{count} detection reviews..." if (count % 25).zero?
        rescue => e
          puts "Error queueing review for detection #{det.id}: #{e.message}"
          Rails.logger.error("Detection #{det.id} review invoke failed: #{e.message}")
          next
        end
      end
    end
    puts "Finished. Total review invocations: #{total}"
  end


  desc "Fetch async inference results"
  task fetch_results: :environment do
    s3 = Aws::S3::Client.new(region: AWS_REGION)

    AsyncInferenceResult.where(status: 'pending', inference_type: "scoring", model_test_id: [17]).find_each do |result|
      m = result.response_location&.match(%r{\As3://([^/]+)/(.+)\z})
      unless m
        Rails.logger.warn("Bad output_location: #{result.response_location.inspect} for AIR #{result.id}")
        next
      end
      bucket, key = m[1], m[2]

      head = begin
        s3.head_object(bucket: bucket, key: key)
      rescue Aws::S3::Errors::NotFound
        puts "Result not ready yet for key: #{key}"
        Rails.logger.info("Result not ready yet for key: #{key}")
        next
      end

      body = begin
        s3.get_object(bucket: bucket, key: key).body.read
      rescue Aws::S3::Errors::NotFound
        Rails.logger.info("Result body not ready yet for key: #{key}")
        next
      end

      out_tokens = begin
        jt = JSON.parse(body)
        text = jt.is_a?(Array) ? jt.first["generated_text"] : jt["generated_text"]
        count_tokens(text.to_s)
      rescue
        0
      end

      process_response(body, result.message, result.model_test, result)

      result.update!(
        status:       'completed',
        duration:     (head.last_modified - result.created_at).to_f,
        output_tokens: out_tokens,
        completed_at: head.last_modified
      )
    rescue Aws::S3::Errors::NoSuchKey
      puts "Result not ready yet for key: #{key}"
      Rails.logger.error("Result not ready yet for key: #{key}")
    end

    puts "Fetch complete."
  end


  # Fetch detection review async results
  desc "Fetch detection review results and update ai_quality_score"
  task fetch_review_results: :environment do
    s3 = Aws::S3::Client.new(region: AWS_REGION)

    processed_mt_ids = Set.new

    AsyncInferenceResult.where(status: "pending", inference_type: "review").find_each do |air|
      begin
        m = air.response_location&.match(%r{\As3://([^/]+)/(.+)\z})
        unless m
          Rails.logger.warn("Bad output_location: #{air.response_location.inspect} for AIR #{air.id}")
          next
        end
        bucket, key = m[1], m[2]

        head = begin
          s3.head_object(bucket: bucket, key: key)
        rescue Aws::S3::Errors::NotFound
          puts "Review result not ready yet for key: #{key}"
          Rails.logger.info("Review result not ready yet for key: #{key}")
          next
        end

        body = begin
          s3.get_object(bucket: bucket, key: key).body.read
        rescue Aws::S3::Errors::NotFound
          puts "Review body not ready yet for key: #{key}"
          Rails.logger.info("Review body not ready yet for key: #{key}")
          next
        end

        out_tokens = begin
          jt = JSON.parse(body)
          text = jt.is_a?(Array) ? jt.first["generated_text"] : jt["generated_text"]
          count_tokens(text.to_s)
        rescue
          0
        end

        process_review_result(body, air)

        air.update!(
          status:        "completed",
          duration:      (head.last_modified - air.created_at).to_f,
          output_tokens: out_tokens,
          completed_at:  head.last_modified
        )
        processed_mt_ids << air.model_test_id
      rescue Aws::S3::Errors::NoSuchKey
        puts "Review result not ready for key: #{key}"
        Rails.logger.warn("Review result not ready for key: #{key}")
      rescue => e
        puts "Failed review fetch for AIR #{air.id}: #{e.message}"
        Rails.logger.error("Failed review fetch for AIR #{air.id}: #{e.class} #{e.message}")
      end
    end
  end


  # ---------- legacy JSON parsers (kept for older formats) ----------

  def process_review_result(raw, air)
    data = JSON.parse(raw) rescue nil
    return false unless data

    obj = data.is_a?(Array) ? data.first : data

    if obj.is_a?(Hash) && obj["generated_text"].is_a?(String)
      inner = extract_review_obj_from_string(obj["generated_text"])
      obj = inner if inner
    end

    score = obj["ai_quality_score"] || obj.dig("output", "ai_quality_score")
    unless score
      puts "No score found for air: #{air.id}"
      return false
    end

    det_id = air.model_test_detection_id
    puts "score: #{score}. detid: #{det_id}"
    detection =
      if det_id
        ModelTestDetection.find_by(id: det_id)
      else
        ModelTestDetection.where(model_test_id: air.model_test_id, message_id: air.message_id)
                          .where(ai_quality_score: nil)
                          .order(created_at: :desc)
                          .first
      end

    unless detection
      puts "No detection mapping for AIR #{air.id}"
      Rails.logger.warn("No detection mapping for AIR #{air.id}")
      return false
    end

    detection.update!(ai_quality_score: score.to_i)
    true
  rescue => e
    Rails.logger.error("process_review_result failed: #{e.class} #{e.message}\nraw=#{raw.to_s[0,500]}")
    false
  end

  def extract_review_obj_from_string(str)
    candidates = str.scan(/\{.*?\}/m).reverse
    candidates.each do |frag|
      next unless frag.include?("ai_quality_score")
      begin
        json = JSON.parse(sanitize_unquoted_keys(frag))
        return json if json.is_a?(Hash)
      rescue
        next
      end
    end
    nil
  end

  def sanitize_unquoted_keys(json_str)
    json_str.gsub(/([{,])\s*(\w+)\s*:/, '\1 "\2":')
  end


  # ---------- SageMaker invoke helpers ----------

  def invoke_realtime_endpoint(endpoint_name, body_json)
    rt = Aws::SageMakerRuntime::Client.new(region: AWS_REGION)
    resp = rt.invoke_endpoint(
      endpoint_name: endpoint_name,
      content_type:  'application/json',
      accept:        'application/json',
      body:          body_json
    )
    resp.body.read
  rescue Aws::SageMakerRuntime::Errors::ServiceError => e
    puts "Realtime invoke failed: #{e.message}"
    Rails.logger.error("Realtime invoke failed: #{e.class} #{e.message}")
    nil
  end

  def invoke_async_endpoint(endpoint_name, payload, prefix: "inputs", key_suffix: nil)
    sagemaker = Aws::SageMakerRuntime::Client.new(region: AWS_REGION)

    response = sagemaker.invoke_endpoint_async(
      endpoint_name:  endpoint_name,
      content_type:   'application/json',
      accept:         'application/json',
      input_location: upload_payload_to_s3(payload, prefix: prefix, key_suffix: key_suffix)
    )

    OpenStruct.new(
      output_location: response.output_location,
      inference_arn:   response.inference_id
    )
  rescue Aws::SageMakerRuntime::Errors::ServiceError => e
    puts "SageMaker async invocation failed: #{e.message}"
    Rails.logger.error("SageMaker async invocation failed: #{e.message}")
    nil
  end

  def upload_payload_to_s3(payload, prefix: "inputs", key_suffix: nil)
    s3_client = Aws::S3::Client.new(region: AWS_REGION)
    bucket    = AWS_BUCKET
    key_body  = key_suffix.present? ? key_suffix : SecureRandom.uuid
    key       = "#{prefix}/#{key_body}.json"
    kms       = ENV["AWS_S3_KMS_KEY_ID"].to_s
    sse_opts  = kms.empty? ? {} : { server_side_encryption: "aws:kms", ssekms_key_id: kms }

    s3_client.put_object(bucket: bucket, key: key, body: payload, **sse_opts)
    "s3://#{bucket}/#{key}"
  end



  # ---------- Helpers to resolve taxonomy and insert rows ----------

  # label -> [metric, submetric, signal_category, indicator_type]
  def resolve_chain_from_label(label, parent_hint = nil)
    base, suffix = if label =~ /(.*)_(Positive|Negative)\z/i
      [$1, $2.downcase]
    else
      [label, nil]
    end
    indicator = suffix # 'positive' | 'negative' | nil

    normalize = ->(s) { s.to_s.strip }
    variants_for = ->(s) do
      b = normalize.call(s)
      alts = [b, b.tr("_"," "), b.tr("-"," "), b.squeeze(" ")]
      (alts + alts.map(&:titleize)).map(&:downcase).uniq
    end

    sub_variants = variants_for.call(base)
    cat_variants = parent_hint ? variants_for.call(parent_hint) : []

    subcategory = SignalSubcategory
                    .includes(:signal_category => [:submetric => :metric])
                    .where("LOWER(signal_subcategories.name) IN (?)", sub_variants)
                    .order(Arel.sql("LENGTH(signal_subcategories.name) ASC"))
                    .first

    category = nil
    submetric = nil
    metric = nil

    if subcategory
      category  = subcategory.signal_category
      submetric = category&.submetric
      metric    = submetric&.metric
    end

    # If we got a subcategory but parent_hint provided, try to align category with hint
    if subcategory && parent_hint.present?
      hinted = SignalCategory.where("LOWER(name) IN (?)", cat_variants).first
      if hinted
        category = hinted
        submetric = category.submetric
        metric    = submetric&.metric
      end
    end

    # If still nothing and we have parent hint, try resolving category first
    if category.blank? && parent_hint.present?
      category = SignalCategory.includes(:submetric => :metric).where("LOWER(name) IN (?)", cat_variants).first
      if category
        submetric = category.submetric
        metric    = submetric&.metric
      end
    end

    # Fallbacks: try direct category name match using the base
    if category.blank?
      category = SignalCategory.includes(:submetric => :metric).where("LOWER(name) IN (?)", sub_variants).first
      if category
        submetric = category.submetric
        metric    = submetric&.metric
      end
    end

    # If still nothing, try submetric by name
    if submetric.blank?
      submetric = Submetric.includes(:metric).where("LOWER(name) IN (?)", sub_variants).first
      metric ||= submetric&.metric
    end

    # If still nothing, try metric by name
    if metric.blank?
      metric = Metric.where("LOWER(name) IN (?)", (cat_variants.presence || sub_variants)).first
    end

    [metric, submetric, category, indicator]
  end


  # Insert detections (RT or async). Stores label/parent + resolved chain + scores.
  def insert_scores_to_detections!(resp_body, model_test, message, air = nil)
    data = JSON.parse(resp_body) rescue nil
    unless data.is_a?(Array) && data.first.is_a?(Hash) && data.first["scores"].is_a?(Array)
      puts "WARN: Unexpected response shape; no 'scores' array found."
      return 0
    end

    scores = data.first["scores"]
    created_or_updated = 0

    scores.each do |row|
      label = row["label"].to_s
      next if label.blank?

      confidence = row["confidence"].to_f
      logit      = row["logit"].to_f
      parent     = row["parent"]
      metric, submetric, category, indicator = resolve_chain_from_label(label, parent)

      attrs = {
        model_test_id:              model_test.id,
        message_id:                 message&.id,
        label:                      label,
        parent_label:               parent,
        metric_id:                  metric&.id,
        submetric_id:               submetric&.id,
        signal_category_id:         category&.id,
        indicator_type:             indicator, # 'positive'|'negative'|nil
      }

      det = ModelTestDetection.find_or_initialize_by(attrs)
      det.async_inference_result_id ||= air&.id
      det.confidence                 = confidence if det.respond_to?(:confidence=)
      det.logit                      = logit      if det.respond_to?(:logit=)
      det.full_output                = row        if det.respond_to?(:full_output=)
      det.save!
      created_or_updated += 1
    rescue => e
      Rails.logger.error("insert_scores_to_detections! failed label=#{label.inspect}: #{e.class} #{e.message}")
      next
    end

    created_or_updated
  end



  # ---------- Token counting & logging ----------

  def count_tokens(text)
    ENCODER.encode(text.to_s).length
  end

  def puts(msg = "")
    super(msg)
    Rails.logger.info(msg) if defined?(Rails) && Rails.logger
  end
end
