# app/controllers/partners/profile_controller.rb
module Partners
  class ProfileController < ApplicationController
    layout "partner"

    before_action :authenticate_user!
    before_action :require_partner!

    def edit
      @topbar_subtitle = "Profile"
    end

    def update
      user = current_user

      attrs = params.require(:user).permit(:first_name, :last_name, :email, :password, :password_confirmation)

      # Keep the same SSO / password rules as Users::RegistrationsController
      auth_provider = user.respond_to?(:auth_provider) ? user.auth_provider.to_s.strip : ""
      provider      = auth_provider.downcase
      is_sso        = provider.present? && !["email", "password"].include?(provider)

      attrs.delete(:current_password)

      if is_sso
        attrs.delete(:email)
        attrs.delete(:unconfirmed_email) if attrs.key?(:unconfirmed_email)

        if attrs[:password].present? || attrs[:password_confirmation].present?
          return redirect_to edit_partners_profile_path, alert: "Password cannot be changed for SSO accounts."
        end

        user.assign_attributes(attrs)
        if user.save
          return redirect_to edit_partners_profile_path, notice: "Profile updated."
        end

        return redirect_to edit_partners_profile_path, alert: user.errors.full_messages.first || "Unable to update profile."
      end

      pw  = attrs[:password].to_s
      pwc = attrs[:password_confirmation].to_s

      if pw.present? || pwc.present?
        if pw.blank? || pwc.blank?
          return redirect_to edit_partners_profile_path, alert: "Password and confirmation are required to change your password."
        end

        if pw != pwc
          return redirect_to edit_partners_profile_path, alert: "Password confirmation does not match password."
        end
      else
        attrs.delete(:password)
        attrs.delete(:password_confirmation)
      end

      user.assign_attributes(attrs)
      if user.save
        bypass_sign_in user, scope: :user
        redirect_to edit_partners_profile_path, notice: "Profile updated."
      else
        redirect_to edit_partners_profile_path, alert: user.errors.full_messages.first || "Unable to update profile."
      end
    end

    private

    def require_partner!
      return if current_user&.respond_to?(:partner?) && current_user.partner?
      redirect_to dashboard_path, alert: "Not authorized."
    end
  end
end
