module Notifiers
  class InviteOutcomeNotifier
    def self.accepted(invite:)
      new(invite).accepted
    end

    def self.declined(invite:)
      new(invite).declined
    end

    def initialize(invite)
      @invite = invite
    end

    def accepted
      notify(:invite_accepted)
    end

    def declined
      notify(:invite_declined)
    end

    private

    attr_reader :invite

    def notify(mailer_method)
      return false unless invite

      reload_invite!
      WorkplaceMailer.public_send(mailer_method, invite: invite).deliver_later
      true
    rescue => e
      Rails.logger.warn("[InviteOutcomeNotifier] #{mailer_method} failed invite_id=#{invite&.id}: #{e.class}: #{e.message}")
      false
    end

    def reload_invite!
      return unless invite&.persisted?

      @invite = invite.reload
    rescue => e
      Rails.logger.warn("[InviteOutcomeNotifier] reload_failed invite_id=#{invite&.id}: #{e.class}: #{e.message}")
      @invite
    end
  end
end
