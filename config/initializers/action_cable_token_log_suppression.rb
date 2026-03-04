# frozen_string_literal: true

# Suppress ActionCable debug logs for token streaming payloads only.
# Leaves all other ActionCable logging untouched.

module ActionCable
  module TokenLogSuppression
    SUPPRESSED_TYPES = %w[token status stream_start done].freeze

    def suppressed_payload?(payload)
      return false unless payload.is_a?(Hash)
      type = payload[:type] || payload["type"]
      SUPPRESSED_TYPES.include?(type.to_s)
    end
    module_function :suppressed_payload?

    module BroadcasterPatch
      def broadcast(message)
        unless ActionCable::TokenLogSuppression.suppressed_payload?(message)
          server.logger.debug do
            "[ActionCable] Broadcasting to #{broadcasting}: #{message.inspect.truncate(300)}"
          end
        end

        payload = { broadcasting: broadcasting, message: message, coder: coder }
        ActiveSupport::Notifications.instrument("broadcast.action_cable", payload) do
          encoded = coder ? coder.encode(message) : message
          server.pubsub.broadcast broadcasting, encoded
        end
      end
    end

    module ChannelBasePatch
      def transmit(data, via: nil)
        unless ActionCable::TokenLogSuppression.suppressed_payload?(data)
          logger.debug do
            status = "#{self.class.name} transmitting #{data.inspect.truncate(300)}"
            status += " (via #{via})" if via
            status
          end
        end

        payload = { channel_class: self.class.name, data: data, via: via }
        ActiveSupport::Notifications.instrument("transmit.action_cable", payload) do
          connection.transmit identifier: @identifier, message: data
        end
      end
    end
  end
end

Rails.application.config.to_prepare do
  if defined?(ActionCable::Server::Broadcasting::Broadcaster)
    patch = ActionCable::TokenLogSuppression::BroadcasterPatch
    unless ActionCable::Server::Broadcasting::Broadcaster < patch
      ActionCable::Server::Broadcasting::Broadcaster.prepend(patch)
    end
  end

  if defined?(ActionCable::Channel::Base)
    patch = ActionCable::TokenLogSuppression::ChannelBasePatch
    unless ActionCable::Channel::Base < patch
      ActionCable::Channel::Base.prepend(patch)
    end
  end
end
