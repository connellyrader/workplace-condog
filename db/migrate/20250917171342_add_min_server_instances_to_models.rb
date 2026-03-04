class AddMinServerInstancesToModels < ActiveRecord::Migration[7.1]
  def change
    add_column :models, :min_server_instances, :integer, default: 0
  end
end
