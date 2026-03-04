# app/services/inference/message_processor.rb
# Processes newly ingested messages:
# - Skips already-queued messages (pending/completed AIR)
# - Detects language (FREE - no API cost)
# - Translates non-English to English (GPT cost only when needed)
# - Queues async inference to SageMaker (S3 input + invoke_endpoint_async)
# - Writes AsyncInferenceResult rows
# - Marks messages as processed + sent_for_inference_at
#
# IMPORTANT CHANGE:
# Non-text messages (images/files/etc.) must not remain processed=false forever. We mark them complete
# immediately so they cannot block onboarding readiness / ETA calculations.
#
# BATCH SAFETY:
# - Sends batched payloads to SageMaker using explicit per-item IDs (AIR IDs)
# - Fetcher can reconcile outputs by AIR ID, not just by array position

module Inference
  class MessageProcessor
    ASYNC_BUCKET = "workplace-io-processing"
    INPUT_PREFIX = "rt-inputs"
    AWS_REGION   = "us-east-2"
    BATCH_SIZE   = ENV.fetch("INFERENCE_BATCH_SIZE", "100").to_i

    def self.call(limit: 500, workspace_id: nil) = new.call(limit: limit, workspace_id: workspace_id)

    def initialize
      creds = Aws::Credentials.new(
        ENV.fetch("AWS_ACCESS_KEY_ID"),
        ENV.fetch("AWS_SECRET_ACCESS_KEY")
      )

      @s3 = Aws::S3::Client.new(region: AWS_REGION, credentials: creds)
      @rt = Aws::SageMakerRuntime::Client.new(region: AWS_REGION, credentials: creds)

      @model_test = ModelTest.active_for_inference
      raise "No active model test configured for inference" unless @model_test

      @mdl = @model_test.model
      raise "Active model test #{@model_test.id} has no model" unless @mdl
      raise "Model #{@mdl.id} missing endpoint_name" if @mdl.endpoint_name.blank?
    end

    def call(limit:, workspace_id: nil)
      remaining = limit.to_i
      last_id   = nil

      counters = {
        queued: 0,
        considered: 0,
        skipped_has_air: 0,
        skipped_blank: 0,
        invoke_failed: 0,
        air_created: 0,
        msg_marked: 0,
        errors: 0,
        translated: 0,
        translation_cached: 0,
        translation_errors: 0,
        batches_sent: 0
      }

      Rails.logger.info(
        "MessageProcessor: up to #{remaining} messages… " \
        "(batch_size=#{BATCH_SIZE} model_test_id=#{@model_test.id} model_id=#{@mdl.id})"
      )

      loop do
        break if remaining <= 0

        scope = base_scope(workspace_id: workspace_id)
        scope = scope.where("messages.id < ?", last_id) if last_id

        # Prioritize newest posted_at first for faster onboarding
        db_batch = scope.order(posted_at: :desc, id: :desc).limit([remaining, 500].min).to_a
        break if db_batch.empty?

        prepared = []

        db_batch.each do |message|
          break if prepared.size >= [BATCH_SIZE, remaining].min

          counters[:considered] += 1

          if already_queued_or_done?(message.id)
            counters[:skipped_has_air] += 1
            next
          end

          raw_text = extract_text(message)

          if raw_text.blank?
            begin
              message.update!(processed: true, processed_at: Time.current, sent_for_inference_at: nil)
              counters[:msg_marked] += 1
            rescue => e
              counters[:errors] += 1
              Rails.logger.error("MessageProcessor: blank_mark_failed msg_id=#{message.id} #{e.class} #{e.message}")
            end

            counters[:skipped_blank] += 1
            next
          end

          lang_result = Language::Service.process_for_inference(raw_text)
          payload_text = lang_result[:text]

          begin
            update_attrs = {}
            update_attrs[:original_language] = lang_result[:source_lang] if message.original_language.blank?
            update_attrs[:text_original] = raw_text if lang_result[:was_translated] && message.text_original.blank?
            message.update!(update_attrs) if update_attrs.present?
          rescue => e
            Rails.logger.error("MessageProcessor: lang_save_failed msg_id=#{message.id} #{e.class} #{e.message}")
          end

          if lang_result[:was_translated]
            counters[:translated] += 1
            counters[:translation_cached] += 1 if lang_result[:translation_cached]
            counters[:translation_errors] += 1 if lang_result[:translation_error]

            Rails.logger.info(
              "MessageProcessor: translated msg_id=#{message.id} " \
              "lang=#{lang_result[:source_lang]} cached=#{lang_result[:translation_cached]}"
            )
          end

          prepared << {
            message: message,
            payload_text: payload_text,
            input_tokens: count_tokens(payload_text)
          }
        end

        if prepared.any?
          queued_count = enqueue_batch!(prepared, counters)
          remaining -= queued_count
          counters[:queued] += queued_count
          counters[:batches_sent] += 1 if queued_count.positive?
        end

        last_id = db_batch.last.id
      end

      Rails.logger.info(
        "[MessageProcessor] done " \
        "queued=#{counters[:queued]} considered=#{counters[:considered]} batches_sent=#{counters[:batches_sent]} " \
        "skipped_has_air=#{counters[:skipped_has_air]} skipped_blank=#{counters[:skipped_blank]} " \
        "invoke_failed=#{counters[:invoke_failed]} air_created=#{counters[:air_created]} " \
        "msg_marked=#{counters[:msg_marked]} errors=#{counters[:errors]} " \
        "translated=#{counters[:translated]} translation_cached=#{counters[:translation_cached]} " \
        "translation_errors=#{counters[:translation_errors]}" \
        "#{workspace_id ? " workspace_id=#{workspace_id}" : ""}"
      )

      counters
    end

    private

    def enqueue_batch!(prepared, counters)
      now = Time.current
      airs = []

      ActiveRecord::Base.transaction do
        prepared.each do |item|
          airs << AsyncInferenceResult.create!(
            model_test_id:  @model_test.id,
            message_id:     item[:message].id,
            status:         "pending",
            input_tokens:   item[:input_tokens],
            inference_type: "scoring",
            provider:       "sagemaker"
          )
        end
      end

      counters[:air_created] += airs.size

      payload_inputs = prepared.zip(airs).map do |item, air|
        { id: air.id.to_s, text: item[:payload_text] }
      end

      body_json = { inputs: payload_inputs }.to_json
      key_suffix = "mt#{@model_test.id}-batch-#{airs.first.id}-#{airs.last.id}"

      ok = put_to_s3_and_invoke(@mdl.endpoint_name, body_json, key_suffix)
      unless ok
        counters[:invoke_failed] += airs.size
        AsyncInferenceResult.where(id: airs.map(&:id)).update_all(status: "failed", completed_at: now)
        return 0
      end

      AsyncInferenceResult.where(id: airs.map(&:id)).update_all(
        response_location: @resp_output,
        inference_arn: @resp_inference_id,
        updated_at: now
      )

      Message.where(id: prepared.map { |i| i[:message].id }).update_all(
        processed: true,
        processed_at: nil,
        sent_for_inference_at: now,
        updated_at: now
      )

      counters[:msg_marked] += airs.size
      airs.size
    rescue => e
      counters[:errors] += 1
      Rails.logger.error("MessageProcessor: batch_error #{e.class} #{e.message}")
      0
    end

    def base_scope(workspace_id:)
      scope = Message.where(processed: false)

      if workspace_id.present?
        scope =
          scope
            .joins(:integration)
            .where(integrations: { workspace_id: workspace_id })
      end

      scope
    end

    def extract_text(message)
      candidates = []

      candidates << message.plaintext if message.respond_to?(:plaintext)
      candidates << message.decrypted_text if message.respond_to?(:decrypted_text)
      candidates << message.text

      candidates.map { |v| v.to_s.strip }.find(&:present?) || ""
    end

    def already_queued_or_done?(message_id)
      AsyncInferenceResult.where(
        model_test_id: @model_test.id,
        message_id: message_id,
        inference_type: "scoring"
      ).where(status: %w[pending completed]).exists?
    end

    def put_to_s3_and_invoke(endpoint_name, body_json, key_suffix)
      s3_key = "#{INPUT_PREFIX}/#{key_suffix}.json"

      @s3.put_object(
        bucket: ASYNC_BUCKET,
        key: s3_key,
        body: body_json,
        content_type: "application/json",
        **s3_encryption_opts
      )

      resp = @rt.invoke_endpoint_async(
        endpoint_name: endpoint_name,
        input_location: "s3://#{ASYNC_BUCKET}/#{s3_key}"
      )

      @resp_output = resp.output_location
      @resp_inference_id = resp.respond_to?(:inference_id) ? resp.inference_id : nil
      true
    rescue => e
      Rails.logger.error("MessageProcessor invoke error: #{e.class} #{e.message}")
      false
    end

    def count_tokens(text) = text.to_s.split(/\s+/).size

    def s3_encryption_opts
      kms = ENV["AWS_S3_KMS_KEY_ID"].to_s
      return {} if kms.empty?

      { server_side_encryption: "aws:kms", ssekms_key_id: kms }
    end
  end
end
