# app/services/ai_chat/sparkline.rb
module AiChat
  class Sparkline
    PURPOSE = :ai_chat_sparkline

    def self.sign!(payload)
      verifier.generate(payload, purpose: PURPOSE, expires_in: 30.minutes)
    end

    def self.verify!(token)
      verifier.verified(token, purpose: PURPOSE)
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
  end
end
