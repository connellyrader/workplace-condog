namespace :sagemaker do
  desc "Recreate a SageMaker endpoint for a ModelTest (env: MODEL_TEST_ID=ID or MT=ID)"
  task recreate_endpoint: :environment do
    mt_id = (ENV["MODEL_TEST_ID"] || ENV["MT"]).to_i
    raise "Set MODEL_TEST_ID or MT to the ModelTest id" if mt_id <= 0

    model_test = ModelTest.find(mt_id)
    model = model_test.model
    raise "ModelTest #{mt_id} has no associated model" unless model

    puts "Recreating endpoint for ModelTest #{model_test.id} using Model #{model.id} (#{model.name})..."
    SageMakerDeploymentJob.perform_now(model.id)
    model.reload
    puts "Done. Endpoint: #{model.endpoint_name.inspect}, status: #{model.status}"
  end
end
