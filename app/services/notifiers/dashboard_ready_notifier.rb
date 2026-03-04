module Notifiers
  class DashboardReadyNotifier
    def self.call(workspace:)
      new(workspace).call
    end

    def initialize(workspace)
      @workspace = workspace
    end

    def call
      return false unless workspace&.owner

      reload_workspace!
      return false if workspace.dashboard_ready_notified_at.present?
      return false unless DashboardReadiness.ready?(workspace_id: workspace.id)

      WorkplaceMailer.dashboard_ready(workspace: workspace).deliver_later
      workspace.update_columns(dashboard_ready_notified_at: Time.current, updated_at: Time.current)
      true
    rescue => e
      Rails.logger.warn("[DashboardReadyNotifier] failed workspace_id=#{workspace&.id}: #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :workspace

    def reload_workspace!
      return unless workspace&.persisted?

      @workspace = workspace.reload
    rescue => e
      Rails.logger.warn("[DashboardReadyNotifier] reload_failed workspace_id=#{workspace&.id}: #{e.class}: #{e.message}")
      @workspace
    end
  end
end
