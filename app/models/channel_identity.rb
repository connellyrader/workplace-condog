class ChannelIdentity < ApplicationRecord
  belongs_to :integration
  belongs_to :channel
  belongs_to :integration_user, optional: true

  PROVIDERS = %w[slack microsoft_teams].freeze

  validates :provider, presence: true
  validates :external_channel_id, presence: true
  validates :external_channel_id,
            uniqueness: { scope: [:integration_id, :provider] }

  before_validation :default_provider

  scope :for_slack, -> { where(provider: "slack") }

  def self.preferred_for(channel:, integration_user: nil, provider: "slack")
    scope = where(channel_id: channel.id, provider: provider)
    scope = scope.where(integration_user_id: integration_user.id) if integration_user

    scope.order(Arel.sql("last_seen_at DESC NULLS LAST, id DESC")).first ||
      where(channel_id: channel.id, provider: provider)
        .order(Arel.sql("last_seen_at DESC NULLS LAST, id DESC"))
        .first
  end

  private

  def default_provider
    self.provider ||= integration&.kind
  end
end
