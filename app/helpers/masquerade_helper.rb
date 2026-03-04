module MasqueradeHelper
  def masquerading?
    session[:masquerade_user_id].present?
  end
end