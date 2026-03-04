class WorkspaceInsightTemplateOverride < ApplicationRecord
  belongs_to :workspace
  belongs_to :trigger_template, class_name: "InsightTriggerTemplate"

  validates :workspace, :trigger_template, presence: true
end
