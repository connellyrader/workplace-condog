class CreateModels < ActiveRecord::Migration[7.1]
  def change
    create_table :models do |t|
      t.string :name, null: false
      t.string :description
      t.string :endpoint_name
      t.string :endpoint_config_name
      t.string :endpoint_arn 
      t.string :endpoint_status, default: 'pending'
      t.string :sagemaker_model_name
      t.string :instance_type, default: 'ml.m5.xlarge'
      t.string :status, default: 'pending'
      t.text :model_info
      t.integer :concurrent_requests, default: 5
      t.integer :max_server_instances, default: 1
      t.string :jumpstart_model_id    # AWS JumpStart ID
      t.string :container_image_uri  # Docker Image URI
      t.string :model_data_url        # S3 model artifact
      t.jsonb :environment_variables, default: {}  # Model-specific env vars
      t.string :deployment_type
      t.string :hf_model_id  
      t.timestamps
    end
  end
end
