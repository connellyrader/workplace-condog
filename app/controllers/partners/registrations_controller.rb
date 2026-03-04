class Partners::RegistrationsController < Devise::RegistrationsController
  layout 'partner'

  def create
    build_resource(sign_up_params)
    resource.partner = true
    resource.save
    yield resource if block_given?
    if resource.persisted?
      if resource.active_for_authentication?
        sign_up(resource_name, resource)

        token = cookies.signed[:pending_invite_token].presence
        if token
          cookies.delete(:pending_invite_token)
          redirect_to invite_path(token) and return
        end

        session[:partner_mode] = true
        redirect_to partner_dashboard_path
      else
        expire_data_after_sign_in!
        redirect_to new_partner_session_path
      end
    else
      clean_up_passwords(resource)
      set_minimum_password_length
      respond_with(resource)
    end
  end

  private

  def sign_up_params
    params.require(:user).permit(
      :first_name,
      :last_name,
      :email,
      :password,
      :password_confirmation
    )
  end
end
