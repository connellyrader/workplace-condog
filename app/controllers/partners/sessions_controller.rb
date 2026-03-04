class Partners::SessionsController < Devise::SessionsController
  layout 'partner'

  def create
    super do |user|
      unless user.partner?
        sign_out user
        flash[:alert] = "You’re not allowed to log in here."
        redirect_to new_partner_session_path and return
      end
    end
  end

  protected

  def after_sign_in_path_for(resource)
    token = cookies.signed[:pending_invite_token].presence
    if token
      cookies.delete(:pending_invite_token)
      return invite_path(token)
    end

    if resource.partner?
      session[:partner_mode] = true
      partner_dashboard_path
    else
      super
    end
  end
end
