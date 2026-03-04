class HealthController < ActionController::Base
  def show
    render plain: "ok", status: :ok
  end
end
