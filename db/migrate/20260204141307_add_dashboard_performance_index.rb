# frozen_string_literal: true

# Add composite index to speed up dashboard queries.
#
# The dashboard does queries like:
#   Detection.joins(message: :integration)
#     .where(integrations: { workspace_id: X })
#     .where("messages.posted_at BETWEEN ? AND ?", start, end)
#     .where("detections.logit_ratio >= ?", threshold)
#
# This partial index covers rows with logit_ratio >= 1.0 (the common threshold)
# and includes message_id + metric_id for efficient joins and metric filtering.
#
class AddDashboardPerformanceIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    # Partial composite index for dashboard queries
    # Covers: message lookup + metric filtering + logit_ratio threshold
    add_index :detections,
              [:message_id, :metric_id, :signal_category_id],
              name: :idx_detections_dashboard_fast,
              where: "logit_ratio >= 1.0",
              algorithm: :concurrently,
              if_not_exists: true

    # Also add an index on messages for the date range + integration lookup
    # (This may already be partially covered, but explicit is better)
    add_index :messages,
              [:integration_id, :posted_at, :id],
              name: :idx_messages_integration_posted_id,
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :detections, name: :idx_detections_dashboard_fast, if_exists: true
    remove_index :messages, name: :idx_messages_integration_posted_id, if_exists: true
  end
end
