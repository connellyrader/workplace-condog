class AddOpenAiFieldsToModels < ActiveRecord::Migration[7.1]
  def change
    change_table :models, bulk: true do |t|
      t.string :openai_model # e.g. "gpt-4o-mini", "gpt-4.1"
    end

    change_table :model_tests, bulk: true do |t|
      t.string :openai_batch_id  # OpenAI batch job id for scoring
      t.string :openai_review_batch_id # optional: batch id for review runs
    end

    change_table :async_inference_results, bulk: true do |t|
      # reuse response_location/inference_arn; add a soft hint field for provider
      t.string :provider # "sagemaker" | "openai"
    end
  end
end
