class Detection < ApplicationRecord
  belongs_to :message
  belongs_to :metric
  belongs_to :submetric
  belongs_to :signal_category
  belongs_to :signal_subcategory, optional: true
  belongs_to :model_test
  belongs_to :async_inference_result

  # All detections under a given app workspace (all integrations)
  scope :for_workspace, ->(workspace_id) {
    joins(message: :integration)
      .where(integrations: { workspace_id: workspace_id })
  }

  scope :in_window, ->(start_date, end_date) {
    where(detections: { created_at: start_date.beginning_of_day..end_date.end_of_day })
  }

  scope :for_metric, ->(metric_id) {
    joins(signal_category: { submetric: :metric })
      .where(submetrics: { metric_id: metric_id })
  }

  scope :with_logit_margin_at_least, ->(threshold) {
    where("detections.logit_margin >= ?", threshold)
  }

  scope :with_scoring_policy, -> {
    where(DetectionPolicy.sql_condition(table_alias: "detections"))
  }
end
