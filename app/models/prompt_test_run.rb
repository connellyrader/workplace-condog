class PromptTestRun < ApplicationRecord
  belongs_to :prompt_version, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :prompt_key, presence: true

  scope :for_key, ->(key) { where(prompt_key: key) }
  scope :for_version, ->(id) {
    if id.present?
      where(prompt_version_id: id)
    else
      where(prompt_version_id: nil)
    end
  }
  scope :recent_first, -> { order(created_at: :desc) }

  def prompt_version_summary
    return nil unless prompt_version

    {
      id: prompt_version.id,
      version: prompt_version.version,
      label: prompt_version.label
    }
  end

  def created_by_summary
    return nil unless created_by

    name = created_by.try(:full_name).presence || created_by.try(:name).presence || created_by.email
    { id: created_by.id, name: name }
  end

  def as_json_for_api
    {
      id: id,
      prompt_key: prompt_key,
      prompt_type: prompt_type,
      title: title,
      body: body,
      metadata: metadata || {},
      created_at: created_at&.iso8601,
      prompt_version: prompt_version_summary,
      created_by: created_by_summary
    }
  end
end
