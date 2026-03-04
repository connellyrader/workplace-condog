class HomeController < ApplicationController
  # Root router.
  #
  # Rules:
  # - Unauthed: go to login.
  # - Partner users default to partner dashboard until they explicitly switch to a client workspace.
  # - Non-partners default to customer dashboard.
  def root
    return redirect_to(new_user_session_path) unless current_user

    if current_user.respond_to?(:partner?) && current_user.partner? && session[:partner_mode]
      return redirect_to partner_dashboard_path
    end

    redirect_to dashboard_path
  end
end
