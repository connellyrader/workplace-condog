# app/jobs/teams_forward_sync_job.rb
class TeamsForwardSyncJob < ApplicationJob
  queue_as :default

  def perform
    Integration
      .joins(:workspace)
      .where(kind: :microsoft_teams)
      .where(workspaces: { archived_at: nil })
      .find_each do |integration|
        Teams::HistorySyncService.new(integration).run_forward!
        integration.update_columns(last_synced_at: Time.current)
      end
  end
end
