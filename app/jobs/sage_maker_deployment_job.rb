class SageMakerDeploymentJob < ApplicationJob
  queue_as :default

  def perform(model_id)
    model = Model.find(model_id)
    model.update(status: 'deploying')

    Rails.logger.error("Model Deployment: #{ model.deployment_type}")
    puts model.deployment_type

    Rails.logger.error("sagemaker model instance: #{model.aws_instance&.instance_type}, #{ model.aws_instance&.instance_type.include?("ml.c") }")
    puts "sagemaker model instance: #{model.aws_instance&.instance_type}, #{ model.aws_instance&.instance_type.include?("ml.c") }"

    # if model.deployment_type == 'Hugging Face Hub'
    #   if model.aws_instance&.instance_type.include?("ml.c")
    #     model.update!(container_image_uri: "763104351884.dkr.ecr.us-east-2.amazonaws.com/huggingface-pytorch-inference:2.6.0-transformers4.51.3-cpu-py312-ubuntu22.04")
    #   else
    #     model.update(container_image_uri: "763104351884.dkr.ecr.us-east-2.amazonaws.com/huggingface-pytorch-tgi-inference:2.7.0-tgi3.3.4-gpu-py311-cu124-ubuntu22.04")
    #   end
    # elsif model.deployment_type == 'Neuron'
    #   model.update(container_image_uri: "763104351884.dkr.ecr.us-east-2.amazonaws.com/huggingface-pytorch-neuronx:2.1.1-neuronx-py310-sdk2.19.0-ubuntu22.04")
    # end

    # If user pasted a DLC URI (e.g., 7631... us-east-1), mirror it first:
    if model.container_image_uri.present?
      dest_uri = SageMaker::EcrDirectMirrorService.new.ensure_mirrored!(model.container_image_uri)
      model.update!(container_image_uri: dest_uri)
    end

    service = SageMaker::EndpointSetupService.new(model)
    service.deploy_async_endpoint

    model.update(
      endpoint_name: service.endpoint_name,
      endpoint_config_name: service.endpoint_config_name,
      status: 'deployed'
    )
  rescue => e
    model.update(status: 'failed')
    Rails.logger.error("SageMaker deployment failed: #{e.message}")
    raise e
  end
end
