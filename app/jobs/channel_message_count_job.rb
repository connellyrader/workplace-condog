class ChannelMessageCountJob < ApplicationJob
  queue_as :default

  def perform(integration_id)
    integration = Integration.find_by(id: integration_id)
    return unless integration

    Slack::ChannelMessageCounter.new(integration).count_all_channels!
  end
end
