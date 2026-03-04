class InsightTriggerTemplate < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :name, :dimension_type, presence: true

  scope :enabled, -> { where(enabled: true) }
  scope :primary_rules, -> { where(primary: true) }

  def subject_scope_list
    subject_scopes.to_s.split(",").map(&:strip).reject(&:blank?)
  end
end
