# app/models/integration.rb
class Integration < ApplicationRecord
  belongs_to :workspace

  has_many :teams,             dependent: :destroy
  has_many :integration_users, dependent: :destroy
  has_many :channels,          dependent: :destroy
  has_many :messages,          dependent: :destroy
  has_many :model_tests,       dependent: :destroy

  # ---- Types of integrations we support ----
  enum kind: {
    slack:           "slack",
    microsoft_teams: "microsoft_teams"
  }

  enum sync_status: {
    queued:     "queued",
    processing: "processing",
    synced:     "synced",
    failed:     "failed"
  }

  validates :name, presence: true

  # Slack-specific requirements
  validates :slack_team_id, :domain,
            presence: true,
            if: :slack?

  # Teams-specific requirements
  validates :ms_tenant_id,
            presence: true,
            if: :microsoft_teams?

  # Slack: unique per workspace
  validates :slack_team_id,
            uniqueness: { scope: :workspace_id },
            allow_nil: true

  # Teams: unique per workspace
  validates :ms_tenant_id,
            uniqueness: { scope: :workspace_id },
            allow_nil: true

  # Compatibility helper: some code expects integration.teams?
  def teams?
    microsoft_teams?
  end

  def setup_complete?
    setup_status == "complete"
  end

  # OLD CODE
  # Kick off background sync for this integration
  # def enqueue_sync!
  #   update!(sync_status: "queued")
  #   TeamsSyncJob.perform_later(id)
  # end

  # ==================================================================
  # Microsoft token refresh helpers (tokens live on IntegrationUser)
  # ==================================================================

  MS_TOKEN_URL = "https://login.microsoftonline.com/organizations/oauth2/v2.0/token".freeze

  # Pick an "installer" integration_user that has a Teams refresh token
  def installer_integration_user
    integration_users
      .where.not(ms_refresh_token: nil)
      .order(:id)
      .first
  end

  # Ensure a valid Microsoft access token exists for the given installer IU.
  # Refreshes if needed and returns the access token string.
  def ensure_ms_access_token!(iu, skew: 5.minutes)
    raise "Integration is not microsoft_teams" unless microsoft_teams?
    raise "No integration_user provided" unless iu

    if iu.ms_access_token.present? && iu.ms_expires_at.present? && iu.ms_expires_at > skew.from_now
      return iu.ms_access_token
    end

    refresh_ms_token_for!(iu)
    iu.ms_access_token
  end

  def refresh_ms_token_for!(iu)
    raise "Integration is not microsoft_teams" unless microsoft_teams?
    raise "No ms_refresh_token for integration_user #{iu.id}" if iu.ms_refresh_token.blank?

    uri  = URI(MS_TOKEN_URL)
    body = {
      client_id:     ENV.fetch("TEAMS_CLIENT_ID"),
      client_secret: ENV.fetch("TEAMS_CLIENT_SECRET"),
      grant_type:    "refresh_token",
      refresh_token: iu.ms_refresh_token
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Rails.env.development? || Rails.env.test?

    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(body)

    response = http.request(request)
    data     = JSON.parse(response.body) rescue {}

    unless response.is_a?(Net::HTTPSuccess) && data["access_token"].present?
      Rails.logger.error "[Integration##{id}] ms token refresh failed for iu=#{iu.id}: #{response.code}"
      raise "Microsoft token refresh failed for integration_user #{iu.id}"
    end

    iu.update!(
      ms_access_token:  data["access_token"],
      ms_refresh_token: data["refresh_token"].presence || iu.ms_refresh_token,
      ms_expires_at:    Time.current + data["expires_in"].to_i.seconds
    )

    iu
  end
end
