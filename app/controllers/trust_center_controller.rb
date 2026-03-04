# app/controllers/trust_center_controller.rb
class TrustCenterController < ApplicationController
  # Public pages
  skip_before_action :authenticate_user!, raise: false
  skip_before_action :lucas_only, raise: false
  skip_before_action :set_active_workspace, raise: false
  skip_before_action :ensure_workspace_ready!, raise: false
  skip_before_action :set_layout_defaults, raise: false
  skip_before_action :set_logit_margin_threshold, raise: false
  skip_before_action :set_right_panel_flags, raise: false

  TRUST_CENTER_STAMP = "December 16, 2025".freeze
  before_action :set_trust_center_stamp

  helper_method :trust_home_url, :trust_doc_url_for

  def index
    @onboarding = true
    @trust_title = "Trust Center"
    @trust_subtitle = "Security, privacy, and compliance resources for Workplace."
  end

  def show
    @onboarding = true
    @slug = params[:slug].to_s
    render "trust_center/docs/#{@slug}"
  rescue ActionView::MissingTemplate
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end

  private

  def set_trust_center_stamp
    @trust_center_stamp = TRUST_CENTER_STAMP
  end

  def trust_home_url
    request.host == "trust.workplace.io" ? "/" : trust_center_path
  end

  def trust_doc_url_for(slug)
    request.host == "trust.workplace.io" ? "/#{slug}" : trust_doc_path(slug)
  end
end
