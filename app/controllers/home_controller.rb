class HomeController < ApplicationController
  # Root router.
  #
  # Rules:
  # - Unauthed: go to login.
  # - Partner users in partner_mode default to the partner dashboard.
  # - Everyone else defaults to the full-screen Assistant (Clara) home.
  def root
    return redirect_to(new_user_session_path) unless current_user

    if current_user.respond_to?(:partner?) && current_user.partner? && session[:partner_mode]
      return redirect_to partner_dashboard_path
    end

    redirect_to clara_home_path
  end
end
