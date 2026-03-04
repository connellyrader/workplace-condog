# app/controllers/users/registrations_controller.rb
class Users::RegistrationsController < Devise::RegistrationsController
  # Rails 7.1: actions must be public
  def update
    self.resource = resource_class.to_adapter.get!(send(:"current_#{resource_name}").to_key)

    if update_resource(resource, account_update_params)
      bypass_sign_in resource, scope: resource_name
      redirect_to settings_profile_path, notice: "Profile updated."
      return
    end

    flash[:alert] = resource.errors.full_messages.first || "Unable to update profile."

    if account_update_params[:password].present? || account_update_params[:password_confirmation].present?
      flash[:open_password_fields] = "1"
    end

    redirect_to settings_profile_path
  end

  protected

  def update_resource(resource, params)
    auth_provider = resource.respond_to?(:auth_provider) ? resource.auth_provider.to_s.strip : ""
    provider      = auth_provider.downcase
    is_sso        = provider.present? && !["email", "password"].include?(provider)

    # You do not want current_password required
    params.delete(:current_password)

    # ---- SSO hard locks ----
    if is_sso
      params.delete(:email)
      params.delete(:unconfirmed_email) if params.key?(:unconfirmed_email)

      if params[:password].present? || params[:password_confirmation].present?
        resource.errors.add(:password, "cannot be changed for SSO accounts.")
        return false
      end

      resource.assign_attributes(params)
      return resource.save
    end

    # ---- Non-SSO: enforce password confirmation in controller ----
    pw  = params[:password].to_s
    pwc = params[:password_confirmation].to_s

    if pw.present? || pwc.present?
      # Require both
      if pw.blank? || pwc.blank?
        resource.errors.add(:password, "and confirmation are required to change your password.")
        return false
      end

      # Require match
      if pw != pwc
        resource.errors.add(:password_confirmation, "does not match password.")
        return false
      end
    else
      # Not changing password → remove keys so blank strings never touch validations
      params.delete(:password)
      params.delete(:password_confirmation)
    end

    resource.assign_attributes(params)
    resource.save
  end

  def after_update_path_for(resource)
    settings_profile_path
  end
end
