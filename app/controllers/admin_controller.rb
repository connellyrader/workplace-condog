class AdminController < ApplicationController
  layout "admin"

  before_action :authenticate_admin

  def index
    # Clean slate admin dashboard.
    # We'll build this out with multiple admin utilities over time.
  end

  def models
    @models = Model.includes(:aws_instance).order(:name)
    @aws_instances = AwsInstance.order(Arel.sql("hourly_price NULLS LAST"), :instance_type)

    render "admin/models/index"
  end
end
