# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :request_id, :active_workspace_id

    def connect
      self.request_id  = SecureRandom.uuid
      self.current_user = find_verified_user
      self.active_workspace_id = find_active_workspace_id
    end

    private

    def find_verified_user
      # ✅ Devise (preferred if you use Devise/Warden)
      if (user = env['warden']&.user)
        return user
      end

      # ✅ Signed/encrypted cookie you set yourself (optional fallback)
      # if (uid = cookies.encrypted[:user_id] || cookies.signed[:user_id])
      #   return User.find_by(id: uid) || reject_unauthorized_connection
      # end

      # ✅ Token via query param (e.g., /cable?ai_chat_token=XYZ) — implement your own lookup
      # if (token = request.params['ai_chat_token']).present?
      #   # Example: User.find_by(ai_chat_token: token)
      #   return ApiToken.find_by(token: token)&.user || reject_unauthorized_connection
      # end

      reject_unauthorized_connection
    end

    def find_active_workspace_id
      session_key = Rails.application.config.session_options[:key] || "_workplace_session"
      session_data = cookies.encrypted[session_key] || {}
      session_data["active_workspace_id"] || session_data[:active_workspace_id]
    rescue => e
      Rails.logger.warn("[ActionCable] Failed to read active workspace from session: #{e.class}: #{e.message}")
      nil
    end
  end
end
