class AddCustomModelData < ActiveRecord::Migration[7.1]
  def change
    add_column :models, :hf_task, :string,  default: "feature-extraction"
    add_column :models, :inference_mode, :string, null: false, default: "async" # "async" | "realtime"
    add_column :models, :hf_dlc_image, :string                                 # optional manual override
  end
end
