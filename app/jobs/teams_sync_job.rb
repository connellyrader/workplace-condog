# app/jobs/workspace_sync_job.rb
class TeamsSyncJob < ApplicationJob
  queue_as :default

  def perform(integration_id)
    integration = Integration.joins(:workspace).find(integration_id)

    if integration.workspace&.archived_at.present?
      Rails.logger.info("[TeamsSyncJob] Skipping archived workspace integration #{integration.id}")
      return
    end

    integration.update!(sync_status: "processing")

    case integration.kind
    when "slack"
      # Slack::IntegrationSetup.new(integration).run!
      # integration.update!(sync_status: "synced", last_synced_at: Time.current)

    when "microsoft_teams"
      Teams::HistorySyncService.new(integration).run_backfill!

      if teams_backfill_remaining?(integration)
        # Still have history to fetch; queue another batch
        integration.update!(sync_status: "queued")
        self.class.set(wait: 1.minute).perform_later(integration.id)
      else
        integration.update!(sync_status: "synced", last_synced_at: Time.current)
        Rails.logger.info "[TeamsSyncJob] Teams backfill complete for integration #{integration.id}"
      end
    end
  rescue => e
    begin
      integration.update!(sync_status: "failed")
    rescue
      # ignore if integration is nil or already gone
    end
    Rails.logger.error("[TeamsSyncJob] Failed for integration #{integration_id}: #{e.class} #{e.message}")
    raise
  end

  private

  def teams_backfill_remaining?(integration)
    return false unless integration.teams?
    integration.channels.where(kind: %w[public_channel private_channel], is_archived: false, backfill_complete: [false, nil]).exists?
  end
end
