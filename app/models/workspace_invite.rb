# app/models/workspace_invite.rb
class WorkspaceInvite < ApplicationRecord
  belongs_to :workspace
  belongs_to :integration_user
  belongs_to :invited_by, class_name: "User"

  enum status: {
    pending:  "pending",
    accepted: "accepted",
    canceled: "canceled",
    expired:  "expired"
  }, _suffix: true

  # Digest-only token storage:
  # - token_digest is persisted
  # - raw_token exists only in memory so you can email the invite link
  attr_accessor :raw_token

  # One-shot "send after commit" flag + token. These are NOT persisted.
  attr_accessor :send_email_after_commit, :raw_token_for_email

  validates :email, presence: true
  validates :token_digest, presence: true, uniqueness: true

  before_validation :normalize_email
  before_validation :ensure_token_digest

  after_commit :deliver_invite_email_if_queued, on: [:create, :update]

  # Lookup helper for invite acceptance, etc.
  def self.find_by_token(token)
    find_by(token_digest: digest_token(token))
  end

  # Generates a high-entropy token suitable for URLs.
  def self.generate_token
    SecureRandom.urlsafe_base64(32)
  end

  # HMAC digest (peppered) so a DB leak does not expose redeemable tokens.
  def self.digest_token(token)
    secret = Rails.application.secret_key_base
    OpenSSL::HMAC.hexdigest("SHA256", secret, token.to_s)
  end

  # Call this immediately before save!/update! when you want to send an invite email.
  # The email will only enqueue AFTER the DB transaction successfully commits.
  def queue_invite_delivery!(raw_token)
    self.send_email_after_commit = true
    self.raw_token_for_email = raw_token.to_s
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end

  # Ensure token_digest is populated before validations run.
  def ensure_token_digest
    return if token_digest.present?

    self.raw_token ||= self.class.generate_token
    self.token_digest = self.class.digest_token(raw_token)
  end

  def deliver_invite_email_if_queued
    return unless send_email_after_commit
    return if raw_token_for_email.to_s.blank?

    # Reset flags so we never double-send if the object is reused in-memory.
    token = raw_token_for_email.to_s
    self.send_email_after_commit = false
    self.raw_token_for_email = nil

    # Use your non-devise mailer
    WorkplaceMailer.workspace_invite(invite: self, token: token).deliver_later
  end
end
