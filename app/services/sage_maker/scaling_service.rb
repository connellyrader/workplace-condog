# app/services/sage_maker/scaling_service.rb
module SageMaker
  class ScalingService
    def initialize(model)
      @model = model
      @region = ENV.fetch('AWS_REGION', 'us-east-2')
      @asg   = Aws::ApplicationAutoScaling::Client.new(region: @region,
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )
      @sm    = Aws::SageMaker::Client.new(region: @region,
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )
      @resource_id = "endpoint/#{@model.endpoint_name}/variant/AllTraffic"
    end

    def apply!(apply_now: false)
      # Update min/max limits
      @asg.register_scalable_target(
        service_namespace: "sagemaker",
        resource_id: @resource_id,
        scalable_dimension: "sagemaker:variant:DesiredInstanceCount",
        min_capacity: @model.min_server_instances,
        max_capacity: @model.max_server_instances
      )

      # Optionally force desired to at least min immediately
      if apply_now
        desired = @model.min_server_instances
        @sm.update_endpoint_weights_and_capacities(
          endpoint_name: @model.endpoint_name,
          desired_weights_and_capacities: [
            { variant_name: "AllTraffic", desired_instance_count: desired }
          ]
        )
      end
      true
    end
  end
end
