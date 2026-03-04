class PromptVersion < ApplicationRecord
  belongs_to :created_by, class_name: "User", optional: true

  scope :for_key, ->(key) { where(key: key).order(version: :desc) }
  scope :active,  -> { where(active: true) }

  before_validation :set_version_number, on: :create
  before_save :deactivate_other_actives_if_needed, if: :active?
  after_commit :enforce_single_active!, on: [:create, :update]

  validates :key, :content, presence: true
  validates :version, numericality: { greater_than: 0 }

  def self.active_for(key)
    active.find_by(key: key)
  end

  def self.active_content(key)
    active_for(key)&.content.to_s.presence
  end

  def self.deactivate_other_actives!(key, except_id: nil)
    return if key.blank?

    scope = where(key: key, active: true)
    scope = scope.where.not(id: except_id) if except_id
    scope.lock.update_all(active: false)
  end

  private

  def set_version_number
    next_version = PromptVersion.where(key: key).maximum(:version).to_i + 1
    self.version = next_version
  end

  def deactivate_other_actives_if_needed
    self.class.deactivate_other_actives!(key, except_id: id)
  end

  def enforce_single_active!
    return unless active?

    PromptVersion.where(key: key, active: true).where.not(id: id).update_all(active: false)
  end
end
