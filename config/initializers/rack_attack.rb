# config/initializers/rack_attack.rb
class Rack::Attack
  # Use Rails cache for throttling state (Redis in prod is ideal)
  Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new if Rails.env.development?

  # Identify the client for throttling
  def self.client_ip(req)
    # If you're behind a proxy/load balancer, ensure Rails is configured with trusted proxies
    req.ip
  end

  # Helpers
  EMAIL_AUTH_PATHS = [
    "/auth/email/lookup",
    "/auth/email/password_sign_in",
    "/auth/email/sign_up"
  ].freeze

  # Throttle by IP across all email-auth endpoints (broad protection)
  throttle("email_auth/ip", limit: 60, period: 1.minute) do |req|
    next unless req.post?
    next unless EMAIL_AUTH_PATHS.include?(req.path)
    client_ip(req)
  end

  # Throttle by IP per endpoint (tighter per-route control)
  throttle("email_auth/lookup/ip", limit: 20, period: 1.minute) do |req|
    next unless req.post?
    next unless req.path == "/auth/email/lookup"
    client_ip(req)
  end

  throttle("email_auth/password_sign_in/ip", limit: 10, period: 1.minute) do |req|
    next unless req.post?
    next unless req.path == "/auth/email/password_sign_in"
    client_ip(req)
  end

  throttle("email_auth/sign_up/ip", limit: 10, period: 1.minute) do |req|
    next unless req.post?
    next unless req.path == "/auth/email/sign_up"
    client_ip(req)
  end

  # Optional: throttle by email (prevents rapid probing of a single address)
  # We normalize the email like the controller does.
  throttle("email_auth/lookup/email", limit: 8, period: 1.minute) do |req|
    next unless req.post?
    next unless req.path == "/auth/email/lookup"
    email = req.params["email"].to_s.strip.downcase
    next if email.blank?
    "#{client_ip(req)}:#{email}"
  end

  # Response when throttled
  self.throttled_responder = lambda do |env|
    # Minimal info; do not reveal anything about existence/provider.
    [429, { "Content-Type" => "application/json" }, [{ ok: false, error: "Too many attempts. Please try again shortly." }.to_json]]
  end
end
