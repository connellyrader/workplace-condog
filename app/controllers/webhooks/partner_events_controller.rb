# app/controllers/webhooks/partner_events_controller.rb
require "openssl"
require "base64"

class Webhooks::PartnerEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_user!
  skip_before_action :lucas_only

  before_action :verify_partner_webhook_signature!

  # POST from Go High Level when partner status changes.
  # When a partner is approved, we provision a login marked as partner,
  # set a temporary password, and email it.
  def receive
    raw = request.raw_post
    payload = JSON.parse(raw) rescue {}

    data = payload["partner_event"].presence || payload

    contact_id = data["contact_id"].to_s.strip
    email      = data["email"].to_s.strip.downcase
    status     = data["Partner Status"].to_s.strip.downcase
    tags_raw   = data["tags"].to_s
    tags       = tags_raw.split(",").map { |t| t.strip.downcase }

    Rails.logger.info "[PartnerWebhook] received contact_id=#{contact_id.presence || 'n/a'} email=#{email.presence || 'n/a'} status=#{status.presence || 'n/a'}"

    if contact_id.blank? || email.blank?
      Rails.logger.warn "[PartnerWebhook] missing contact_id/email"
      return head :ok
    end

    ev = PartnerProvisioningEvent.find_or_create_by!(contact_id: contact_id) do |e|
      e.email   = email
      e.payload = payload
      e.status  = "received"
    end

    # Idempotency: if already processed, do nothing.
    return head :ok if ev.processed?

    unless status == "approved" || tags.include?("partner - approved")
      ev.update!(status: "skipped", processed_at: Time.current)
      return head :ok
    end

    user = User.where("LOWER(email) = ?", email).first_or_initialize
    user.email = email
    user.first_name ||= data["first_name"].to_s.strip.presence
    user.last_name  ||= data["last_name"].to_s.strip.presence
    user.partner = true

    temp_password = SecureRandom.base58(12)
    user.password = temp_password
    user.password_confirmation = temp_password

    user.save!

    PartnerMailer.account_access(user: user, password: temp_password).deliver_later

    ev.update!(status: "processed", user_id: user.id, processed_at: Time.current)

    head :ok
  rescue => e
    Rails.logger.error "[PartnerWebhook] failed: #{e.class} #{e.message}"
    begin
      ev&.update!(status: "failed", error: "#{e.class}: #{e.message}")
    rescue
      # ignore
    end
    head :ok
  end

  private

  def verify_partner_webhook_signature!
    secret = ENV["PARTNER_WEBHOOK_SECRET"].to_s
    if secret.blank?
      Rails.logger.error "[PartnerWebhook] missing PARTNER_WEBHOOK_SECRET; rejecting request"
      return head :service_unavailable
    end

    raw = request.raw_post.to_s
    supplied = request.headers["X-Partner-Signature"].presence ||
               request.headers["X-Webhook-Signature"].presence ||
               bearer_token_from_authz

    if supplied.blank?
      Rails.logger.warn "[PartnerWebhook] missing signature header"
      return head :unauthorized
    end

    timestamp = request.headers["X-Partner-Timestamp"].to_s.presence ||
                request.headers["X-Webhook-Timestamp"].to_s.presence

    unless valid_partner_signature?(secret: secret, raw: raw, supplied: supplied, timestamp: timestamp)
      Rails.logger.warn "[PartnerWebhook] invalid signature"
      return head :unauthorized
    end

    if timestamp.present?
      ts = Integer(timestamp) rescue nil
      if ts.nil? || (Time.now.to_i - ts).abs > 5.minutes.to_i
        Rails.logger.warn "[PartnerWebhook] stale/invalid timestamp"
        return head :unauthorized
      end
    end
  end

  def valid_partner_signature?(secret:, raw:, supplied:, timestamp: nil)
    signatures = []

    signatures << OpenSSL::HMAC.hexdigest("SHA256", secret, raw)
    signatures << Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, raw))

    if timestamp.present?
      signed_payload = "#{timestamp}.#{raw}"
      signatures << OpenSSL::HMAC.hexdigest("SHA256", secret, signed_payload)
      signatures << Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, signed_payload))
    end

    supplied_norm = supplied.to_s.strip.sub(/\Asha256=/i, "")
    signatures.any? { |sig| ActiveSupport::SecurityUtils.secure_compare(sig, supplied_norm) }
  end

  def bearer_token_from_authz
    auth = request.headers["Authorization"].to_s
    return nil if auth.blank?

    m = auth.match(/\ABearer\s+(.+)\z/i)
    m && m[1].to_s.strip.presence
  end
end
