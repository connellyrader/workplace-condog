# app/jobs/run_model_test_job.rb
class RunModelTestJob < ApplicationJob
  queue_as :default

  def perform(model_test_id)
    model_test    = ModelTest.find(model_test_id)
    integration   = model_test.integration
    model_endpoint = model_test.model.endpoint_name

    previous_message_count   = 5  # adjustable context length
    previous_detection_count = 3  # adjustable previous detection length

    # Iterate messages for this integration
    integration.messages.order(:posted_at).find_each do |message|
      context  = build_context(message, previous_message_count, previous_detection_count, model_test)
      response = invoke_endpoint(model_endpoint, context)
      process_response(response, message, model_test)
    end
  end

  private

  def build_context(message, prev_msg_count, prev_det_count, model_test)
    messages_context =
      message.previous_messages(prev_msg_count).pluck(:text).join("\n")

    detections_context =
      ModelTestDetection
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

  def invoke_endpoint(endpoint_name, payload)
    sagemaker = Aws::SageMakerRuntime::Client.new(region: 'us-east-1',
    credentials: Aws::Credentials.new(
      ENV.fetch("AWS_ACCESS_KEY_ID"),
      ENV.fetch("AWS_SECRET_ACCESS_KEY")
    )
  )

    sagemaker.invoke_endpoint(
      endpoint_name: endpoint_name,
      content_type:  'application/json',
      body:          payload
    ).body.read
  rescue Aws::SageMakerRuntime::Errors::ServiceError => e
    Rails.logger.error("SageMaker invocation failed: #{e.message}")
    nil
  end

  def process_response(response, message, model_test)
    return unless response

    parsed = JSON.parse(response) rescue nil
    return unless parsed.is_a?(Array)

    parsed.each do |scored_signal|
      detection_score       = scored_signal['score']
      detection_description = scored_signal['description']
      submetric_id          = scored_signal['submetric_id'] # assuming your payload has this

      next unless detection_score && detection_description && submetric_id

      ModelTestDetection.create!(
        model_test:  model_test,
        message:     message,
        submetric_id: submetric_id,
        description: detection_description,
        score:       detection_score
      )
    end
  rescue => e
    Rails.logger.error("RunModelTestJob process_response failed: #{e.class} #{e.message}")
  end
end
