module Notifiers
  class TeamsAdminApprovalNotifier
    def self.call(user:)
      new(user).call
    end

    def initialize(user)
      @user = user
    end

    def call
      return false unless user&.email.present?

      WorkplaceMailer.teams_admin_approved(user: user).deliver_later
      true
    rescue => e
      Rails.logger.warn("[TeamsAdminApprovalNotifier] failed user_id=#{user&.id}: #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :user
  end
end
