class DashboardReadiness
  READY_DAYS_THRESHOLD = 60

  def self.ready?(workspace_id:)
    return false if workspace_id.blank?

    scope = Integration.joins(:workspace)
                       .where(workspace_id: workspace_id)
                       .where(workspaces: { archived_at: nil })
    return false unless scope.exists?

    scope.where(analyze_complete: true).exists? ||
      scope.maximum(:days_analyzed).to_i >= READY_DAYS_THRESHOLD
  end
end
