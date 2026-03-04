module Notifiers
  class WorkspaceWelcomeNotifier
    def self.call(workspace:)
      new(workspace).call
    end

    def initialize(workspace)
      @workspace = workspace
    end

    def call
      return false unless workspace&.owner

      reload_workspace!
      return false if workspace.welcome_notified_at.present?

      WorkplaceMailer.welcome(workspace: workspace).deliver_later
      workspace.update_columns(welcome_notified_at: Time.current, updated_at: Time.current)
      true
    rescue => e
      Rails.logger.warn("[WorkspaceWelcomeNotifier] failed workspace_id=#{workspace&.id}: #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :workspace

    def reload_workspace!
      return unless workspace&.persisted?

      @workspace = workspace.reload
    rescue => e
      Rails.logger.warn("[WorkspaceWelcomeNotifier] reload_failed workspace_id=#{workspace&.id}: #{e.class}: #{e.message}")
      @workspace
    end
  end
end
