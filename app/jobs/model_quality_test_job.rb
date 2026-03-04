# app/jobs/model_quality_test_job.rb
class ModelQualityTestJob < ApplicationJob
  queue_as :default

  def perform(model_test_ids, prev_msg_count: 5, prev_det_count: 3)
    ModelTest.where(id: model_test_ids).includes(:integration, :model).find_each do |mt|
      endpoint = mt.model.endpoint_name

      mt.model_test_detections.includes(:message).find_each do |det|
        payload = generate_context_for_review(mt, prev_msg_count, det, prev_det_count)
        raw     = invoke_endpoint(endpoint, payload)
        next unless raw

        update_detection(det, raw)
      end

      mt.update!(ai_quality_reviewed: true)
    end
  end

  private

  def invoke_endpoint(endpoint_name, payload)
    client = Aws::SageMakerRuntime::Client.new(region: "us-east-1",
      credentials: Aws::Credentials.new(
        ENV.fetch("AWS_ACCESS_KEY_ID"),
        ENV.fetch("AWS_SECRET_ACCESS_KEY")
      )
    )
    client.invoke_endpoint(
      endpoint_name: endpoint_name,
      content_type:  "application/json",
      body:          payload
    ).body.read
  rescue Aws::SageMakerRuntime::Errors::ServiceError => e
    Rails.logger.error("SageMaker quality invoke failed: #{e.message}")
    nil
  end

  def update_detection(detection, raw_json)
    parsed = JSON.parse(raw_json) rescue {}
    score  = parsed["ai_quality_score"] || parsed.dig(0, "ai_quality_score")
    return unless score

    detection.update!(ai_quality_score: score)
  rescue => e
    Rails.logger.error("Update detection #{detection.id} failed: #{e.class} #{e.message}")
  end

  def generate_context_for_review(model_test, prev_msg_count, detection, prev_det_count)
    message           = detection.message
    messages_context  = message.previous_messages(prev_msg_count).pluck(:text).join("\n")
    detections_context = ModelTestDetection
                           .where(model_test: model_test)
                           .order(created_at: :desc)
                           .limit(prev_det_count)
                           .pluck(:description)
                           .join("\n")

    {
      current_message:     message.text,
      previous_messages:   messages_context,
      previous_detections: detections_context,
      test_context:        model_test.context
    }.to_json
  end
end
