# app/controllers/dev_controller.rb
# Development-only controller for local setup (fake login, etc.).
# All actions are disabled outside development.
class DevController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :lucas_only
  skip_before_action :set_active_workspace
  skip_before_action :ensure_workspace_ready!
  skip_before_action :set_unread_insights
  skip_before_action :redirect_restricted_users!
  skip_before_action :set_right_panel_flags

  before_action :ensure_development!

  # GET /dev/login?email=demo@example.com
  # Signs in the user without password (dev only). Redirects to dashboard.
  def login
    email = params[:email].to_s.strip.downcase.presence
    unless email
      return redirect_to root_path, alert: "Usage: /dev/login?email=demo@example.com"
    end

    user = User.find_by(email: email)
    unless user
      return redirect_to root_path, alert: "No user with email #{email}. Run: rails db:seed"
    end

    sign_in(:user, user, bypass: true)

    # Force Demo Workspace so user sees dummy data (admins can access it)
    dw = Workspace.find_by(name: DemoData::Generator::DEMO_WORKSPACE_NAME)
    if dw && (user.admin? || (user.respond_to?(:partner?) && user.partner?))
      session[:active_workspace_id] = dw.id
    end

    redirect_to dashboard_path
  end

  private

  def ensure_development!
    return if Rails.env.development?

    head :not_found
  end
end
