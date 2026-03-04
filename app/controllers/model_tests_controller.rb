class ModelTestsController < ApplicationController
  layout "admin"

  before_action :authenticate_admin
  before_action :set_model_test, only: [:show, :update]
  before_action :find_next_detection, only: [:detection_review]


  def index
    @model_tests = ModelTest
                    .includes(:model, :signal_category, integration: :workspace)
                    .order(created_at: :desc)

    @models            = Model.order(:name)
    @workspaces        = Workspace.order(:name)
    @signal_categories = SignalCategory.order(:name)
    @aws_instances     = AwsInstance.order(Arel.sql("hourly_price NULLS LAST"), :instance_type)
  end


  def create_model
    params[:model].delete(:custom_api_params_json) unless params.dig(:model, :deployment_type) == "Custom API"

    # --- Handle model artifact modes ---
    artifact_mode = params.dig(:model, :artifact_mode).to_s
    file          = params.dig(:model, :artifact_file)
    s3_url_param  = params.dig(:model, :model_data_url).to_s.presence
    prefix_param  = params.dig(:model, :artifact_s3_prefix).to_s.presence

    bucket = ENV.fetch("SAGEMAKER_ARTIFACT_BUCKET", "workplace-io-processing")
    prefix = (prefix_param || "model-artifacts").sub(%r{\A/}, "").sub(%r{/\z}, "")

    # Upload file if requested
    if artifact_mode == "upload" && file.present?
      # Generate key: model-artifacts/<parameterized-name>-<timestamp>.tar.gz
      base = params.dig(:model, :name).to_s.parameterize
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      key = "#{prefix}/#{base}-#{timestamp}.tar.gz"

      s3 = Aws::S3::Client.new(
        region: ENV.fetch("AWS_REGION", "us-east-2"),
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )

      kms_key  = ENV["AWS_S3_KMS_KEY_ID"].presence
      sse_opts = kms_key ? { server_side_encryption: "aws:kms", ssekms_key_id: kms_key } : {}

      File.open(file.tempfile, "rb") do |io|
        s3.put_object(bucket: bucket, key: key, body: io, **sse_opts)
      end

      # Overwrite the param to point to S3
      params[:model][:model_data_url] = "s3://#{bucket}/#{key}"
    elsif artifact_mode == "s3_url"
      # trust the provided S3 url (basic check)
      unless s3_url_param&.start_with?("s3://")
        redirect_to admin_models_path, alert: "Provide a valid S3 URI (s3://...)" and return
      end
    else
      # artifact_mode == "none": clear model_data_url so DLC downloads from HF
      params[:model][:model_data_url] = nil
    end

    @model = Model.new(model_params)

    if @model.save
      redirect_to admin_models_path, notice: 'Model was successfully created.'
    else
      redirect_to admin_models_path, alert: @model.errors.full_messages.to_sentence
    end
  end

  def create
    @model_test = ModelTest.new(model_test_params)
    if @model_test.save
      redirect_to model_tests_path, notice: 'Model test was successfully created.'
    else
      redirect_to model_tests_path, alert: @model_test.errors.full_messages.to_sentence
    end
  end

  def show
    @model_test = ModelTest
                    .includes(:model, :signal_category, integration: :workspace)
                    .find(params[:id])

    @model     = @model_test.model
    @workspace = @model_test.workspace
    @category  = @model_test.signal_category

    # Detections + rollups
    @detections = @model_test.model_test_detections.includes(:signal_subcategory, :signal_category)
    @det_count  = @detections.count

    human_scope = @detections.where.not(human_quality_score: nil)
    ai_scope    = @detections.where.not(ai_quality_score: nil)

    @avg_quality = (
      human_scope.average(:human_quality_score) || ai_scope.average(:ai_quality_score)
    )&.to_f&.round(1)

    # Test rollups (prefer values stored on model_tests; fall back to AIR sums)
    airs_scoring = AsyncInferenceResult.where(model_test_id: @model_test.id, inference_type: 'scoring')
    @input_tokens  = @model_test.input_tokens  || airs_scoring.sum(:input_tokens).to_i
    @output_tokens = @model_test.output_tokens || airs_scoring.sum(:output_tokens).to_i

    # Duration (seconds): prefer mt.duration; else earliest->latest completion window
    if @model_test.duration.present?
      @duration_sec = @model_test.duration.to_f
    else
      earliest = airs_scoring.minimum(:created_at)
      latest   = airs_scoring.where.not(completed_at: nil).maximum(:completed_at)
      @duration_sec = earliest && latest ? (latest - earliest).to_f : nil
    end

    # Estimated cost (if not already present), using model.aws_instance.hourly_price
    @estimated_cost =
      if @model_test.estimated_cost.present?
        @model_test.estimated_cost.to_f/100
      elsif @duration_sec && @model&.aws_instance_id
        price = AwsInstance.where(id: @model.aws_instance_id).pick(:hourly_price).to_f
        (((@duration_sec / 3600.0) * price * @model.max_server_instances)/100.0).round(2)
      end

    # Status: running if any pending AIRs; else completed
    has_pending = AsyncInferenceResult.where(model_test_id: @model_test.id, status: 'pending').exists?
    @status_text = has_pending ? 'running' : 'completed'
    @status_badge_class = has_pending ? 'mtt-badge--warn' : 'mtt-badge--ok'

    @provider = @model_test.provider

    # Workspace facts
    @channels_count = @workspace ? @workspace.channels.count : 0
    @users_count    = @workspace ? @workspace.workspace_users.count : 0
    @messages_count = AsyncInferenceResult.where(model_test_id: @model_test.id, inference_type: 'scoring').count

    # Chart data — overall quality
    quality_scores = @detections.map { |d| d.ai_quality_score }.compact

    # Build 11 buckets for integer scale 0..10
    bins = Array.new(11, 0)
    quality_scores.each do |s|
      # map 0..100 -> 0..10
      idx = (s.to_f).floor.clamp(0, 10)
      bins[idx] += 1
    end
    @quality_bins = bins

    # Chart data — subcategory detections (top 8 by volume)
    subcat_counts = Hash.new(0)

    @detections.each do |d|
      # Count every detection into its subcategory bucket (no score required)
      if d.signal_subcategory.present? && d.signal_subcategory.signal_category_id == @model_test.signal_category_id
        label = d.signal_subcategory&.name || d.signal_category&.name
        subcat_counts[label] += 1
      end
    end

    # First: pick the top 8 by count
    top_subcats = subcat_counts.sort_by { |(_label, count)| -count }#.first(8)

    # Second: order those top 8 alphabetically by label
    top_subcats.sort_by! { |label, _count| label.downcase }

    @subcat_labels = top_subcats.map(&:first)
    @subcat_counts = top_subcats.map(&:last)

    # Dynamic y-axis step/ceiling derived from the largest bucket size
    max_count = @subcat_counts.max || 0
    @subcat_step =
      if    max_count >= 500 then 100
      elsif max_count >= 200 then 50
      elsif max_count >= 100 then 20
      elsif max_count >= 50  then 10
      elsif max_count >= 20  then 5
      else                       1
      end

    @subcat_suggested_max =
      if max_count.zero?
        10
      else
        ((max_count.to_f / @subcat_step).ceil * @subcat_step).to_i
      end



    # Chart data — polarity
    @polarity_pos = @detections.where(indicator_type: 'positive').count
    @polarity_neg = @detections.where(indicator_type: 'negative').count

  end


  def update
    if @model_test.status == 'pending' && @model_test.update(model_test_params)
      redirect_to model_tests_path, notice: 'Model test was successfully updated.'
    else
      redirect_to model_tests_path, alert: @model_test.errors.full_messages.to_sentence
    end
  end

  def detection_review
    @model_test = @detection.model_test
    @model      = @model_test.model
    @workspace  = @model_test.workspace

    @message    = @detection.message
    @previous_messages = @message.previous_messages(@model_test.prev_message_count).order(:posted_at)

    @scoring_instructions = @model_test.scoring_instructions
    @output_instructions  = @model_test.output_instructions

    @taxonomy = {
      metric:        @detection.signal_category&.submetric&.metric&.name,
      submetric:     @detection.signal_category&.submetric&.name,
      category:      @detection.signal_category&.name,
      subcategory:   @detection.signal_subcategory&.name,
      indicator_type:@detection.indicator_type # 'positive' or 'negative'
    }

    @total_reviewed = ModelTestDetection.joins(:message => [:workspace_user]).where(:model_test_id => @model_test.id).where.not(human_quality_score: nil).where("workspace_users.user_id = #{current_user.id}").count
    @total_reviews_remaining = ModelTestDetection.joins(:message => [:workspace_user]).where(:model_test_id => @model_test.id, human_quality_score: nil).where("workspace_users.user_id = #{current_user.id}").count
  end

  def submit_detection_review
    det_id = params[:detection_id].to_i
    score  = params[:quality_score].to_i
    user   = current_user || User.find(2) # replace fallback with current_user if you’re using Devise

    detection = ModelTestDetection.find_by(id: det_id)
    unless detection
      redirect_to model_tests_path(), alert: "Detection not found."
      return
    end

    # Force a SQL update regardless of validations
    changed = ModelTestDetection.where(id: det_id)
                                .update_all(human_quality_score: score, updated_at: Time.current)

    Rails.logger.info("[review] set human_quality_score=#{score} for detection=#{det_id} (rows=#{changed})")

    mt = detection.model_test
    pending = ModelTestDetection.exists?(model_test_id: mt.id, human_quality_score: nil)
    mt.update_column(:human_quality_reviewed, true) unless pending

    # Compute the next oldest unreviewed in the user’s channels
    next_det = ModelTestDetection
                 .joins(:message)
                 .where(ai_quality_score: nil, human_quality_score: nil, model_test_id: mt.id)
                 .where(messages: { channel_id: user.channel_ids })
                 .order("messages.posted_at ASC, model_test_detections.id ASC")
                 .limit(1)
                 .pick(:id)

    if next_det
      redirect_to detection_review_path(model_test_id: detection.model_test_id), notice: "Review saved. Next detection loaded."
    else
      redirect_to model_test_path(mt), notice: "Review saved. No more detections left to review."
    end
  rescue => e
    Rails.logger.error("[review] submit failed: #{e.class} #{e.message}")
    redirect_back fallback_location: model_tests_path, alert: "Failed to save review."
  end


  def update_scaling
    id = params[:id] || params.dig(:model, :id)
    model = Model.find(id)

    if model.deployment_type == "OpenAI Batch API"
      redirect_to admin_models_path, alert: "OpenAI models don’t use SageMaker autoscaling."
      return
    end
    if model.endpoint_name.blank?
      redirect_to admin_models_path, alert: "Endpoint not deployed yet; cannot update scaling."
      return
    end

    attrs = params.require(:model).permit(:min_server_instances, :max_server_instances, :apply_now)
    min   = attrs[:min_server_instances].to_i
    max   = attrs[:max_server_instances].to_i
    apply_now = ActiveModel::Type::Boolean.new.cast(attrs[:apply_now])

    if min < 0 || max < 1 || min > max
      redirect_to admin_models_path, alert: "Invalid values: ensure 0 ≤ min ≤ max and max ≥ 1."
      return
    end

    model.update!(min_server_instances: min, max_server_instances: max)

    SageMaker::ScalingService.new(model).apply!(apply_now: apply_now)

    note = "Updated autoscaling to min=#{min}, max=#{max}"
    note += " (applied now)" if apply_now
    redirect_to admin_models_path, notice: note
  rescue => e
    Rails.logger.error("update_scaling failed: #{e.class} #{e.message}")
    redirect_to admin_models_path, alert: "Failed to update autoscaling: #{e.message}"
  end


  def toggle_endpoint
    model = Model.find(params[:id])

    unless model.inference_mode.to_s == 'realtime'
      redirect_to admin_models_path, alert: "Only realtime models support on/off toggle." and return
    end

    enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])

    if enabled
      # Turn ON: (re)create endpoint
      if model.status.to_s == 'deployed' && model.endpoint_name.present?
        redirect_to admin_models_path, notice: "#{model.name} is already on." and return
      end
      model.update!(status: 'deploying')
      SageMakerDeploymentJob.perform_later(model.id)
      redirect_to admin_models_path, notice: "Starting #{model.name}…"
    else
      # Turn OFF: delete endpoint (keep model/config for fast resume)
      if model.endpoint_name.blank?
        model.update!(status: 'pending', endpoint_status: 'Deleted')
        redirect_to admin_models_path, notice: "#{model.name} is already off." and return
      end

      sm = Aws::SageMaker::Client.new(region: ENV.fetch('AWS_REGION', 'us-east-2'),
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )
      begin
        sm.delete_endpoint(endpoint_name: model.endpoint_name)
      rescue Aws::SageMaker::Errors::ResourceNotFound
        # already gone
      end

      model.update!(
        status:               'pending',
        endpoint_status:      'Deleted',
        endpoint_arn:         nil,
        endpoint_name:        nil,
        endpoint_config_name: nil
        # (leave sagemaker_model_name so we can redeploy faster; or nil it if you prefer a fresh name)
      )
      redirect_to admin_models_path, notice: "Stopped #{model.name}."
    end
  rescue => e
    Rails.logger.error("toggle_endpoint failed: #{e.class} #{e.message}")
    redirect_to admin_models_path, alert: "Toggle failed: #{e.message}"
  end




  private

  # If you want to compute a “next” URL server-side:
  def detection_next_path
    url_for(action: :detection_review)
  end

  def set_model_test
    @model_test = ModelTest.find(params[:id])
  end

  def model_test_params
    params.require(:model_test).permit(
      :name,
      :description,
      :test_type,
      :context,
      :workspace_id,
      :model_id,
      :active,
      :prev_message_count,
      :prev_detection_count,
      :scoring_instructions,
      :output_instructions,
      :signal_category_id)
  end

  def model_params
    p = params.require(:model).permit(
      :name,
      :description,
      :jumpstart_model_id,
      :container_image_uri,
      :model_data_url,
      :instance_type,
      :aws_instance_id,
      :max_server_instances,
      :min_server_instances,
      :concurrent_requests,
      :deployment_type,
      :environment_variables,
      :hf_model_id,
      :openai_model,
      :hf_dlc_image,
      :inference_mode,
      :hf_task,
      :artifact_mode,
      :artifact_s3_prefix,
      :artifact_file
    )

    # normalize JSONB env vars to a Hash (so we don't pass an empty string)
    if p[:environment_variables].is_a?(String)
      p[:environment_variables] =
        if p[:environment_variables].strip.present?
          JSON.parse(p[:environment_variables]) rescue {}
        else
          {}
        end
    end

    p
  end


  def find_next_detection
    @detection = ModelTestDetection
      .joins(:message)
      .includes(:signal_category, :signal_subcategory, :message, model_test: [:model, { integration: :workspace }])
      .where(human_quality_score: nil)
      .where(model_test_id: params[:model_test_id], messages: { workspace_user_id: WorkspaceUser.where(user_id: current_user.id) })
      .order('messages.posted_at ASC, model_test_detections.id ASC')
      .first
  end
end
