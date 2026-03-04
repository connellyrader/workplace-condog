# app/jobs/slack_user_hydration_job.rb
class SlackUserHydrationJob < ApplicationJob
  queue_as :default

  def perform(integration_id, integration_user_id)
    integration = Integration.find(integration_id)
    iu = IntegrationUser.find(integration_user_id)

    return unless integration.kind == "slack"
    return unless iu.slack_history_token.present?

    Slack::UserHydrator.new(integration: integration, iu: iu).run!
  end
end
