# app/jobs/teams_user_hydration_job.rb
class TeamsUserHydrationJob < ApplicationJob
  queue_as :default

  def perform(integration_id, integration_user_id)
    integration = Integration.find(integration_id)
    iu = IntegrationUser.find(integration_user_id)

    return unless integration.kind.to_s == "microsoft_teams"
    return unless iu.integration_id == integration.id
    return if iu.ms_refresh_token.blank?

    Teams::UserHydrator.new(integration: integration, iu: iu).run!
  end
end
