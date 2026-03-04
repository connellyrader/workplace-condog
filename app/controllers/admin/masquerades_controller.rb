class Admin::MasqueradesController < ApplicationController
  layout "admin"
  before_action :authenticate_admin, only: [:create]
  before_action :authenticate_masquerade_exit, only: [:destroy]

  def create
    target_user = User.find(params[:id])
    
    log_masquerade(:start, target_user.id)
    
    # Store masquerade info in session
    session[:masquerade_user_id] = target_user.id
    session[:masquerade_admin_id] = current_user.id
    
    # Sign in as the target user
    sign_in(target_user, bypass: true)
    
    flash[:notice] = "Now masquerading as #{target_user.email}"
    redirect_to root_path
  end

  def destroy
    target_id = session[:masquerade_user_id]
    admin_id = session[:masquerade_admin_id]
    
    log_masquerade(:stop, target_id)
    
    if admin_id
      admin_user = User.find_by(id: admin_id)
      sign_in(admin_user, bypass: true) if admin_user&.admin?
    end
    
    # Clear masquerade session
    session.delete(:masquerade_user_id)
    session.delete(:masquerade_admin_id)
    
    flash[:notice] = "Stopped masquerading"
    redirect_to admin_users_path
  end

  private

  def authenticate_masquerade_exit
    return if session[:masquerade_admin_id].present? && session[:masquerade_user_id].present?

    authenticate_admin
  end

  def log_masquerade(action, target_id = nil)
    Rails.logger.info(
      "[Masquerade] action=#{action} admin_id=#{current_user&.id} target_id=#{target_id} ip=#{request.remote_ip}"
    )
  end
end
