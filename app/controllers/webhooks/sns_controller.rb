# # app/controllers/webhooks/sns_controller.rb
class Webhooks::SnsController < ActionController::API
#   require "aws-sdk-sns"
#   require "aws-sdk-s3"
#   require "json"
#   require "net/http"
#   require "uri"
#
#   # SNS -> SageMaker Async completion webhook
#   # - Verifies SNS signature
#   # - For notifications, fetches the output JSON from S3
#   # - Upserts Detection rows (one per polarity) and computes logit_margin vs thresholds
#   # - Marks the source Message as processed when done
#   def sagemaker_async
#     raw = request.raw_post.to_s
#
#     verifier = Aws::SNS::MessageVerifier.new
#     unless verifier.authentic?(raw)
#       Rails.logger.warn("[SNS] signature verification failed")
#       return head :unauthorized
#     end
#
#     msg = JSON.parse(raw)
#
#     case msg["Type"]
#     when "SubscriptionConfirmation"
#       url = msg["SubscribeURL"].to_s
#       Rails.logger.info("[SNS] SubscriptionConfirmation: #{url}")
#       Net::HTTP.get(URI.parse(url)) # confirm
#       head :ok
#
#     when "Notification"
#       handle_notification!(msg)
#       head :ok
#
#     else
#       head :ok
#     end
#   rescue JSON::ParserError => e
#     Rails.logger.warn("[SNS] JSON parse error: #{e.message}")
#     head :bad_request
#   rescue => e
#     Rails.logger.error("[SNS] webhook error: #{e.class} #{e.message}")
#     head :ok
#   end
#
#   private
#
#   def handle_notification!(msg)
#     payload = JSON.parse(msg["Message"]) rescue {}
#     status  = (payload["Status"] || payload["status"]).to_s.presence || "Completed"
#     outloc  = (payload["OutputLocation"] || payload["outputLocation"]).to_s
#     inf_id  = (payload["InferenceId"]  || payload["inferenceId"]).to_s
#     reason  = (payload["FailureReason"] || payload["failureReason"]).to_s
#
#     air = if inf_id.present?
#       AsyncInferenceResult.where(inference_arn: inf_id).order(created_at: :desc).first
#     else
#       AsyncInferenceResult.where(response_location: outloc).order(created_at: :desc).first
#     end
#
#     unless air
#       Rails.logger.warn("[SNS] No AsyncInferenceResult for InferenceId=#{inf_id} OutputLocation=#{outloc.inspect}")
#       return
#     end
#
#     if status.casecmp("Failed").zero?
#       air.update!(status: "failed", completed_at: Time.current)
#       # also mark message finished (failed)
#       Message.where(id: air.message_id).update_all(processed: true, processed_at: Time.current)
#       Rails.logger.warn("[SNS] Inference failed (air_id=#{air.id}): #{reason}")
#       return
#     end
#
#     # Fallback to stored response_location when SNS omits OutputLocation
#     outloc = air.response_location if outloc.blank?
#     if outloc.blank?
#       Rails.logger.error("[SNS] Missing OutputLocation (SNS & AIR) for air_id=#{air.id}")
#       return
#     end
#
#     json_docs = fetch_s3_json_with_retry(outloc, retries: 3, sleep: 0.3)
#     if json_docs.nil?
#       Rails.logger.error("[SNS] Could not read output at #{outloc} (air_id=#{air.id})")
#       return
#     end
#
#     # Our transform_fn returns: [[ { "label":..., "logit":... }, ... ]]
#     flat = json_docs.is_a?(Array) ? json_docs.first : []
#     unless flat.is_a?(Array)
#       Rails.logger.error("[SNS] Unexpected output format at #{outloc}: #{json_docs.class}")
#       return
#     end
#
#     upsert_detections!(air, flat)
#
#     # mark inference + message complete
#     air.update!(status: "completed", completed_at: Time.current)
#     Message.where(id: air.message_id).update_all(processed: true, processed_at: Time.current)
#   end
#
#   # ------ S3 helpers ------
#
#   def fetch_s3_json_with_retry(s3_uri, retries:, sleep:)
#     bucket, key = parse_s3_uri(s3_uri)
#     return nil if bucket.blank? || key.blank?
#
#     s3 = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-east-2"),
        # credentials: Aws::Credentials.new(
        #   ENV.fetch("AWS_ACCESS_KEY_ID"),
        #   ENV.fetch("AWS_SECRET_ACCESS_KEY")
        # )
      # )
#     tries = 0
#     begin
#       resp = s3.get_object(bucket: bucket, key: key)
#       JSON.parse(resp.body.read)
#     rescue Aws::S3::Errors::NoSuchKey
#       tries += 1
#       return nil if tries > retries
#       Kernel.sleep(sleep)
#       retry
#     rescue => e
#       Rails.logger.error("[SNS] S3 fetch error for #{s3_uri}: #{e.class} #{e.message}")
#       nil
#     end
#   end
#
#   def parse_s3_uri(uri)
#     unless uri.to_s.start_with?("s3://")
#       Rails.logger.warn("[SNS] OutputLocation is not s3://: #{uri.inspect}")
#       return [nil, nil]
#     end
#     stripped = uri.sub(%r{\As3://}i, "")
#     parts = stripped.split("/", 2)
#     [parts.first, parts.last]
#   end
#
#   # ------ persistence into detections ------
#
#   # Writes one row per {label, logit} into detections with upsert semantics on
#   # (message_id, signal_category_id, model_test_id, polarity)
#   def upsert_detections!(air, label_logits)
#     model_test_id = air.model_test_id
#     message_id    = air.message_id
#
#     @sc_cache ||= {} # memoize SignalCategory by id
#     created = 0
#
#     label_logits.each do |obj|
#       label = obj["label"].to_s
#       logit = obj["logit"].to_f
#       next if label.blank?
#
#       sc_id = resolve_signal_category_id(label)
#       next unless sc_id
#
#       polarity = label =~ /_Positive\z/i ? "positive" : "negative"
#       score    = polarity == "positive" ? 100 : 0
#
#       sc    = (@sc_cache[sc_id] ||= SignalCategory.find(sc_id))
#       thr   = (polarity == "positive" ? sc.positive_threshold : sc.negative_threshold)
#       ratio = begin
#         t = Float(thr) rescue nil
#         t && t != 0.0 ? (logit / t) : nil
#       end
#
#       det = Detection.find_or_initialize_by(
#         message_id:         message_id,
#         signal_category_id: sc_id,
#         model_test_id:      model_test_id,
#         polarity:           polarity
#       )
#
#       det.assign_attributes(
#         async_inference_result_id: air.id,
#         full_output:               obj,    # raw per-polarity payload
#         score:                     score,  # 100 or 0
#         logit_score:               logit,  # raw logit from model
#         logit_margin:               ratio   # logit / threshold (nil if no/zero threshold)
#       )
#       det.save!
#       created += 1
#     end
#
#     Rails.logger.info("[SNS] Upserted #{created} detections (polarity rows) for AIR #{air.id}")
#   end
#
#   # Map "Tracking_Goals_Alignment_Positive" -> base "Tracking_Goals_Alignment"
#   # Resolve to SignalCategory via Template.signal -> Template.signal_category -> SignalCategory.name
#   def resolve_signal_category_id(label)
#     base = label.sub(/_(Positive|Negative)\z/i, "")
#
#     # Try matching Template.signal (case-insensitive; underscores/spaces normalized)
#     tmpl = Template.where("REPLACE(LOWER(signal), ' ', '_') = ?", base.downcase).first
#     if tmpl
#       sc = SignalCategory.find_by("REPLACE(LOWER(name), ' ', '_') = ?", tmpl.signal_category.to_s.downcase.gsub(" ", "_"))
#       return sc.id if sc
#     end
#
#     # Fallback: direct match on SignalCategory name
#     sc = SignalCategory.find_by("REPLACE(LOWER(name), ' ', '_') = ?", base.downcase)
#     sc&.id
#   end
end
