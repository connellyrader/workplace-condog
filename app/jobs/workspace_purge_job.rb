class WorkspacePurgeJob < ApplicationJob
  queue_as :low

  retry_on StandardError, wait: :exponentially_longer, attempts: 10

  def perform(workspace_id, request_id: nil, requested_by: nil)
    WorkspacePurger.new(
      workspace_id: workspace_id,
      request_id: request_id,
      requested_by: requested_by
    ).call
  end
end
