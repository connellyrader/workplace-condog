class User < ApplicationRecord

  encrypts :slack_sso_token

  # Devise + OpenID Connect SSO
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :omniauthable, omniauth_providers: [:slack_sso, :slack_history, :google_oauth2, :entra_id]

  # External identities in Slack/Teams, etc.
  has_many :integration_users, dependent: :destroy
  has_many :integrations,     through: :integration_users

  # Workspaces where this user is the canonical owner
  has_many :owned_workspaces,
          class_name: "Workspace",
          foreign_key: :owner_id,
          inverse_of: :owner,
          dependent: :destroy

  # Membership via join table
  has_many :workspace_users, dependent: :destroy
  has_many :workspaces, through: :workspace_users

  # Messages they posted across all integrations (via their integration_users)
  has_many :messages, through: :integration_users

  has_many :insights, as: :subject, dependent: :destroy

  has_many :links, dependent: :destroy

  has_many :ai_chat_conversations,
           class_name: "AiChat::Conversation",
           dependent: :destroy

  # Subscriptions they own as customers
  has_many :subscriptions, dependent: :destroy

  # Charges they earn commission on as affiliates
  has_many :affiliate_charges,
           class_name: "Charge",
           foreign_key: :affiliate_id,
           dependent: :nullify

  # Charges they paid as customers (optional)
  has_many :customer_charges,
           class_name:  "Charge",
           foreign_key: :customer_id,
           dependent:   :nullify

  # Payouts this user has received (as affiliate)
  has_many :payouts, dependent: :nullify

  # All saved payout methods (e.g. PayPal, Trolley)
  has_many :payout_methods, dependent: :destroy

  # User who referred this user (via a link)
  belongs_to :referred_by_link, class_name: "Link", optional: true

  # Users referred by this user's links
  has_many :referral_links,  class_name: "Link", foreign_key: :user_id
  has_many :referred_users,  through: :referral_links, source: :users


  AUTH_PROVIDERS = %w[password slack google microsoft].freeze
  validates :auth_provider, inclusion: { in: AUTH_PROVIDERS }, allow_nil: true

  def default_payout_method
    payout_methods.find_by(is_default: true)
  end

  def total_unpaid_commission
    affiliate_charges.where(payout_id: nil).sum(:commission)
  end

  def total_accrued_commissions
    affiliate_charges.where(payout_id: nil).sum(:commission)
  end

  def previous_month_payout_amount
    range = Date.today.prev_month.beginning_of_month..Date.today.prev_month.end_of_month
    affiliate_charges.where(payout_id: nil, created_at: range).sum(:commission)
  end

  def full_name
    [first_name, last_name].compact.join(" ")
  end

  # Called from Users::OmniauthCallbacksController#slack_sso
  def self.from_slack_sso(auth)
    email = auth&.info&.email.to_s.strip.downcase
    raise ArgumentError, "Slack SSO did not return an email address" if email.blank?

    # ✅ Case-insensitive lookup to avoid duplicate-create when provider casing changes
    user = User.where("LOWER(email) = ?", email).first_or_initialize
    user.email = email

    # Store the OIDC token if you still need it (consider encrypting or removing long-term)
    user.slack_sso_token = auth&.credentials&.token if auth&.credentials&.token.present?

    user.first_name ||= auth&.info&.first_name
    user.last_name  ||= auth&.info&.last_name

    user.password = Devise.friendly_token[0, 20] if user.new_record?

    user.save!
    user
  end

  # Channel memberships inferred from messages (portable, no extra tables needed)
  def channel_ids
    messages.distinct.pluck(:channel_id)
  end
end
