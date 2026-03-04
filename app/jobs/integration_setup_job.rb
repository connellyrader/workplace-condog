# app/jobs/integration_setup_job.rb
class IntegrationSetupJob < ApplicationJob
  queue_as :default

  def perform(integration_id)
    integration = Integration.find(integration_id)

    integration.update!(
      setup_status:       "processing",
      setup_started_at:   Time.current,
      setup_completed_at: nil,
      setup_error:        nil,
      setup_step:         "starting",
      setup_progress:     1
    )

    case integration.kind
    when "slack"
      run_slack_setup!(integration)
    when "microsoft_teams"
      run_teams_setup!(integration)
    else
      raise "Unknown integration kind=#{integration.kind}"
    end

    # refresh counts (cheap and reliable)
    integration.reload
    integration.update!(
      setup_users_count: IntegrationUser.where(integration_id: integration.id, is_bot: false, active: true).count,
      setup_channels_count: Channel.where(integration_id: integration.id, kind: "public_channel", is_archived: false).count,
      setup_memberships_count: ChannelMembership.where(integration_id: integration.id, left_at: nil).count,
      setup_status: "complete",
      setup_step: "complete",
      setup_progress: 100,
      setup_completed_at: Time.current
    )

    ChannelMessageCountJob.perform_later(integration.id) if integration.kind == "slack"
  rescue => e
    begin
      integration&.update(
        setup_status: "failed",
        setup_error: "#{e.class}: #{e.message}",
        setup_step: "failed"
      )
    rescue
      # don't hide original error
    end
    raise
  end

  private

  def run_slack_setup!(integration)
    integration.update!(setup_step: "importing_directory", setup_progress: 10)

    svc = Slack::IntegrationSetup

    if svc.respond_to?(:call)
      svc.call(integration)
      return
    end

    obj = svc.new(integration)
    if obj.respond_to?(:run!)
      obj.run!
      return
    end

    if obj.respond_to?(:call)
      obj.call
      return
    end

    raise "Slack::IntegrationSetup has no supported entrypoint (.call, #run!, #call)"
  end

  def run_teams_setup!(integration)
    integration.update!(setup_step: "importing_directory", setup_progress: 10)

    svc = Teams::IntegrationSetup

    if svc.respond_to?(:call)
      svc.call(integration)
      return
    end

    obj = svc.new(integration)
    if obj.respond_to?(:run!)
      obj.run!
      return
    end

    if obj.respond_to?(:call)
      obj.call
      return
    end

    raise "Teams::IntegrationSetup has no supported entrypoint (.call, #run!, #call)"
  end
end
