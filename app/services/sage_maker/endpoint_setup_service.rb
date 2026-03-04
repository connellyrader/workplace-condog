module SageMaker
  class EndpointSetupService
    attr_reader :model, :endpoint_name, :endpoint_config_name, :sagemaker_model_name

    def initialize(model)
      @model = model
      @region = ENV.fetch('AWS_REGION', 'us-east-2')
      @sagemaker   = Aws::SageMaker::Client.new(region: @region,
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )
      @autoscaling = Aws::ApplicationAutoScaling::Client.new(region: @region,
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )
      @cloudwatch  = Aws::CloudWatch::Client.new(region: @region,
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )

      @sagemaker_model_name = "model-#{ENV['MODEL_SERVER_CONFIG_NAME']}-#{model.id}-#{model.name.parameterize}"
      @endpoint_name = "endpoint-#{ENV['MODEL_SERVER_CONFIG_NAME']}-#{model.id}-#{model.name.parameterize}"
      @endpoint_config_name = "endpoint-config-#{ENV['MODEL_SERVER_CONFIG_NAME']}-#{model.id}-#{model.name.parameterize}"
      @resource_id = "endpoint/#{@endpoint_name}/variant/AllTraffic"
    end

    def deploy_async_endpoint
      create_sagemaker_model
      create_endpoint_config
      create_endpoint

      wait_for_endpoint_in_service

      setup_auto_scaling

      model.update!(
        sagemaker_model_name: @sagemaker_model_name,
        endpoint_name: @endpoint_name,
        endpoint_config_name: @endpoint_config_name,
        endpoint_arn: fetch_endpoint_arn,
        endpoint_status: fetch_endpoint_status,
        status: 'deployed'
      )
    end

    private

    def create_sagemaker_model
      @sagemaker.create_model(
        model_name: @sagemaker_model_name,
        execution_role_arn: ENV.fetch('AWS_SAGEMAKER_EXECUTION_ROLE', "arn:aws:iam::388410206920:role/SageMakerAllInOneRole"),
        primary_container: container_config
      )
    rescue Aws::SageMaker::Errors::ValidationException => e
      if e.message =~ /already existing model/i
        Rails.logger.info("Reuse existing SageMaker Model #{@sagemaker_model_name}")
      else
        Rails.logger.error("Failed to create SageMaker Model: #{e.message}")
        raise
      end
    end



    # def container_config
    #   {
    #     image: model.container_image_uri,
    #     environment: JSON.parse(model.environment_variables)
    #   }
    # end

    # def container_config
    #   env = model.environment_variables

    #   # accept string or hash
    #   if env.is_a?(String)
    #     env = env.strip.present? ? JSON.parse(env) : {}
    #   end
    #   env = {} unless env.is_a?(Hash)

    #   # SageMaker requires string values
    #   env = env.transform_keys(&:to_s)
    #            .transform_values { |v| v.nil? ? "" : v.to_s }

    #   {
    #     image: model.container_image_uri.to_s,
    #     environment: env
    #   }
    # end

    def container_config
      env = model.effective_env
      {
        image: model.effective_image(region: @region),
        environment: env
      }.tap do |h|
        h[:model_data_url] = model.model_data_url.to_s if model.model_data_url.present?
      end
    end

    def create_endpoint_config
      prod = {
        model_name:  @sagemaker_model_name,
        variant_name:"AllTraffic",
        instance_type: model.aws_instance.instance_type,
        initial_instance_count: 1,
        container_startup_health_check_timeout_in_seconds: 3600
      }
      prod[:volume_size_in_gb] = 250 if supports_volume_size?(prod[:instance_type])

      args = {
        endpoint_config_name: @endpoint_config_name,
        production_variants: [prod]
      }
      args[:async_inference_config] = {
        output_config: {
          s3_output_path: "s3://workplace-io-processing/async-results/#{@sagemaker_model_name}/"
        },
        client_config: { max_concurrent_invocations_per_instance: model.max_server_instances }
      } if model.async?

      @sagemaker.create_endpoint_config(**args)
    rescue Aws::SageMaker::Errors::ValidationException => e
      if e.message =~ /already existing endpoint[- ]?config/i
        Rails.logger.info("Reuse existing EndpointConfig #{@endpoint_config_name}")
      else
        Rails.logger.error("Failed to create EndpointConfig: #{e.message}")
        raise
      end
    end


    def create_endpoint
      @sagemaker.create_endpoint(
        endpoint_name: @endpoint_name,
        endpoint_config_name: @endpoint_config_name
      )
    end

    def setup_auto_scaling
      # Scalable target is the same for both modes
      @autoscaling.register_scalable_target(
        service_namespace: "sagemaker",
        resource_id: @resource_id,
        scalable_dimension: "sagemaker:variant:DesiredInstanceCount",
        min_capacity: model.min_server_instances,
        max_capacity: model.max_server_instances
      )

      if model.async?
        # ---- Async step scaling (your existing alarms) ----
        scale_up_policy = @autoscaling.put_scaling_policy(
          policy_name: "scale-up-from-zero-#{@endpoint_name}",
          service_namespace: "sagemaker",
          resource_id: @resource_id,
          scalable_dimension: "sagemaker:variant:DesiredInstanceCount",
          policy_type: "StepScaling",
          step_scaling_policy_configuration: {
            adjustment_type: "ChangeInCapacity",
            cooldown: 60,
            metric_aggregation_type: "Average",
            step_adjustments: [{ metric_interval_lower_bound: 0, scaling_adjustment: 1 }]
          }
        )

        @cloudwatch.put_metric_alarm(
          alarm_name: "alarm-scale-up-zero-#{@endpoint_name}",
          namespace: "AWS/SageMaker",
          metric_name: "HasBacklogWithoutCapacity",
          statistic: "Average",
          threshold: 1,
          comparison_operator: "GreaterThanOrEqualToThreshold",
          evaluation_periods: 1,
          period: 60,
          dimensions: [
            { name: "EndpointName", value: @endpoint_name },
            { name: "VariantName", value: "AllTraffic" }
          ],
          alarm_actions: [scale_up_policy.policy_arn],
          treat_missing_data: "notBreaching"
        )

        aggressive_scale_out_policy = @autoscaling.put_scaling_policy(
          policy_name: "aggressive-scale-out-#{@endpoint_name}",
          service_namespace: "sagemaker",
          resource_id: @resource_id,
          scalable_dimension: "sagemaker:variant:DesiredInstanceCount",
          policy_type: "StepScaling",
          step_scaling_policy_configuration: {
            adjustment_type: "ChangeInCapacity",
            cooldown: 120,
            metric_aggregation_type: "Average",
            step_adjustments: [
              { metric_interval_lower_bound: 0,   metric_interval_upper_bound: 45,  scaling_adjustment: 1 },
              { metric_interval_lower_bound: 45,  metric_interval_upper_bound: 195, scaling_adjustment: 3 },
              { metric_interval_lower_bound: 195,                              scaling_adjustment: 5 }
            ]
          }
        )

        @cloudwatch.put_metric_alarm(
          alarm_name: "alarm-aggressive-scale-out-#{@endpoint_name}",
          namespace: "AWS/SageMaker",
          metric_name: "ApproximateBacklogSizePerInstance",
          statistic: "Average",
          threshold: 5,
          comparison_operator: "GreaterThanThreshold",
          evaluation_periods: 1,
          period: 60,
          dimensions: [{ name: "EndpointName", value: @endpoint_name }],
          alarm_actions: [aggressive_scale_out_policy.policy_arn],
          treat_missing_data: "notBreaching"
        )

        scale_in_policy = @autoscaling.put_scaling_policy(
          policy_name: "scale-in-when-idle-#{@endpoint_name}",
          service_namespace: "sagemaker",
          resource_id: @resource_id,
          scalable_dimension: "sagemaker:variant:DesiredInstanceCount",
          policy_type: "StepScaling",
          step_scaling_policy_configuration: {
            adjustment_type: "ChangeInCapacity",
            cooldown: 60,
            metric_aggregation_type: "Average",
            step_adjustments: [{ metric_interval_upper_bound: 0, scaling_adjustment: -1 }]
          }
        )

        @cloudwatch.put_metric_alarm(
          alarm_name: "alarm-scale-in-when-idle-#{@endpoint_name}",
          namespace: "AWS/SageMaker",
          metric_name: "ApproximateBacklogSizePerInstance",
          statistic: "Average",
          threshold: 1,
          comparison_operator: "LessThanThreshold",
          evaluation_periods: 5,
          period: 60,
          dimensions: [{ name: "EndpointName", value: @endpoint_name }],
          alarm_actions: [scale_in_policy.policy_arn],
          treat_missing_data: "breaching"
        )
      else
        # ---- Real-time: target-tracking on InvocationsPerInstance ----
        @autoscaling.put_scaling_policy(
          policy_name: "tt-invocations-#{@endpoint_name}",
          service_namespace: "sagemaker",
          resource_id: @resource_id,
          scalable_dimension: "sagemaker:variant:DesiredInstanceCount",
          policy_type: "TargetTrackingScaling",
          target_tracking_scaling_policy_configuration: {
            predefined_metric_specification: {
              predefined_metric_type: "SageMakerVariantInvocationsPerInstance"
            },
            target_value: (model.concurrent_requests.to_f * 0.8), # aim for ~80% load
            scale_out_cooldown: 60,
            scale_in_cooldown: 120
          }
        )
      end
    end


    def scale_endpoint_to_zero
      @sagemaker.update_endpoint_weights_and_capacities({
        endpoint_name: @endpoint_name,
        desired_weights_and_capacities: [
          {
            variant_name: 'AllTraffic',
            desired_instance_count: 0
          }
        ]
      })
    end

    # def update_cloudwatch_alarm
    #   alarm_name = "TargetTracking-endpoint/#{@endpoint_name}/variant/AllTraffic-AlarmLow"

    #   @cloudwatch.put_metric_alarm({
    #     alarm_name: alarm_name,
    #     comparison_operator: "LessThanThreshold",
    #     evaluation_periods: 15,
    #     threshold: model.concurrent_requests.to_f * 0.9,
    #     namespace: "AWS/SageMaker",
    #     metric_name: "InvocationsPerInstance",
    #     statistic: "Sum",
    #     period: 60,
    #     dimensions: [
    #       { name: "EndpointName", value: @endpoint_name },
    #       { name: "VariantName", value: "AllTraffic" }
    #     ],
    #     treat_missing_data: "breaching"
    #   })
    # end

    def wait_for_endpoint_in_service
      loop do
        status = fetch_endpoint_status
        break if %w[InService Failed].include?(status)

        Rails.logger.info("Waiting for endpoint to be InService. Current status: #{status}")
        sleep 30
      end
    end

    def fetch_endpoint_arn
      @sagemaker.describe_endpoint(endpoint_name: @endpoint_name).endpoint_arn
    rescue Aws::SageMaker::Errors::ServiceError => e
      Rails.logger.error("Failed to fetch endpoint ARN: #{e.message}")
      nil
    end

    def fetch_endpoint_status
      @sagemaker.describe_endpoint(endpoint_name: @endpoint_name).endpoint_status
    rescue Aws::SageMaker::Errors::ServiceError => e
      Rails.logger.error("Failed to fetch endpoint status: #{e.message}")
      'unknown'
    end

    def supports_volume_size?(instance_type)
      # Disallow common GPU/accelerator families where VolumeSize isn’t supported
      disallowed_prefixes = %w[ml.g ml.p ml.inf2 ml.trn]
      disallowed_prefixes.none? { |p| instance_type.start_with?(p) }
    end
  end
end
