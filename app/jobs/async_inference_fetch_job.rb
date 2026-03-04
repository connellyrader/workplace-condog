class AsyncInferenceFetchJob < ApplicationJob
  queue_as :default

  def perform(output_s3_uri, inference_id, payload = {})
    return unless output_s3_uri.present?

    region = ENV.fetch("AWS_REGION", "us-east-2")
    s3     = Aws::S3::Client.new(region: region,
      credentials: Aws::Credentials.new(
        ENV.fetch("AWS_ACCESS_KEY_ID"),
        ENV.fetch("AWS_SECRET_ACCESS_KEY")
      )
    )

    bucket, key = parse_s3(output_s3_uri)
    body   = s3.get_object(bucket: bucket, key: key).body.read

    air = AsyncInferenceResult.find_by(inference_arn: inference_id) ||
          AsyncInferenceResult.find_by(response_location: output_s3_uri)


    # replace below with handling of json from s3 that has label/logit scores
    # insert every label/logit to table

    if air
      # Optional: count tokens, etc., like your rake task
      out_tokens = safe_count_output_tokens(body)
      # Reuse your existing processor:
      Webhooks::AsyncResultProcessor.process(body, air) if defined?(Webhooks::AsyncResultProcessor)
      air.update!(status: "completed", output_tokens: out_tokens, completed_at: Time.current)
    else
      Rails.logger.info("No AIR match for inference_id=#{inference_id} (#{output_s3_uri})")
    end
  end

  private

  def parse_s3(uri)
    m = uri.match(%r{\As3://([^/]+)/(.+)\z}i) or raise "Bad S3 URI: #{uri}"
    [m[1], m[2]]
  end

  def safe_count_output_tokens(body)
    jt = JSON.parse(body) rescue nil
    text = if jt.is_a?(Array) then jt.first["generated_text"] else jt&.dig("generated_text") end
    ModelTest::ENCODER.encode(text.to_s).length rescue 0
  end
end
