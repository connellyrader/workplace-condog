module Admin
  class PartnerResourcesController < ApplicationController
    layout "admin"

    before_action :authenticate_admin
    before_action :set_partner_resource, only: [:edit, :update, :destroy]

    def index
      @partner_resources = PartnerResource.ordered
    end

    def new
      @partner_resource = PartnerResource.new
    end

    def create
      @partner_resource = PartnerResource.new(partner_resource_params)

      if @partner_resource.save
        redirect_to admin_partner_resources_path, notice: "Resource created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @partner_resource.update(partner_resource_params)
        redirect_to admin_partner_resources_path, notice: "Resource updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @partner_resource.destroy!
      redirect_to admin_partner_resources_path, notice: "Resource deleted."
    end

    private

    def set_partner_resource
      @partner_resource = PartnerResource.find(params[:id])
    end

    def partner_resource_params
      params.require(:partner_resource).permit(:category, :resource_type, :title, :url, :hex, :position, :file)
    end
  end
end
