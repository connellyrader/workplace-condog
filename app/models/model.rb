class Model < ApplicationRecord
  belongs_to :aws_instance, optional: true

  after_commit :deploy_sagemaker_endpoint, on: :create, if: :sagemaker_deploy?

  validates :max_server_instances, numericality: { greater_than: 0 }
  validates :concurrent_requests,  numericality: { greater_than: 0 }
  validates :min_server_instances, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :max_server_instances, numericality: { greater_than_or_equal_to: 1 }
  validate  :min_lte_max
  before_validation :sync_instance_type_from_aws_instance
  validate :validate_deployment_specifics

  attr_accessor :artifact_mode, :artifact_file, :artifact_s3_prefix

  def min_lte_max
    return if min_server_instances.nil? || max_server_instances.nil?
    errors.add(:min_server_instances, "must be ≤ max_server_instances") if min_server_instances > max_server_instances
  end

  def hourly_price = aws_instance&.hourly_price

  # Add "Neuron Instance" to keep UI in sync
  def sagemaker_deploy?
    true
    # %w[Hugging Face Hub Neuron Neuron Instance Custom API].include?(deployment_type)
  end

  def openai_deploy? = (deployment_type == "OpenAI Batch API")

  # ---- NEW helpers for dynamic HF deployment ----
  def async?    = inference_mode.to_s == "async"
  def realtime? = !async?

  def hf_task_or_default = hf_task.presence || "feature-extraction"

  # Choose a DLC image automatically unless explicitly set on the model
  def effective_image(region: ENV.fetch("AWS_REGION", "us-east-2"))
    return container_image_uri if container_image_uri.present?
    return hf_dlc_image if hf_dlc_image.present?
    base = "763104351884.dkr.ecr.#{region}.amazonaws.com/huggingface-pytorch-inference:2.6.0-transformers4.51.3-"
    suffix =
      if aws_instance&.instance_type.to_s.start_with?("ml.g","ml.p","ml.trn","ml.inf2")
        "gpu-py312-cu124"
      else
        "cpu-py312"
      end
    "#{base}#{suffix}-ubuntu22.04"
  end

  def effective_env
    # ensure strings
    environment_variables
    # (environment_variables || {}).transform_keys(&:to_s).transform_values { |v| v.to_s }.merge(
    #   "HF_MODEL_ID"               => (hf_model_id.presence || "microsoft/deberta-v3-base"),
    #   "HF_TASK"                   => hf_task_or_default,
    #   "HF_HUB_ENABLE_HF_TRANSFER" => "1"
    # )
  end

  private

  def sync_instance_type_from_aws_instance
    self.instance_type ||= aws_instance&.instance_type
  end

  def deploy_sagemaker_endpoint
    SageMakerDeploymentJob.perform_later(id)
  end

  def validate_deployment_specifics
    if openai_deploy?
      errors.add(:openai_model, "is required for OpenAI Batch API") if openai_model.blank?
    else
      errors.add(:aws_instance_id, "is required for non-OpenAI deployments") if aws_instance_id.blank?
    end
  end
end
