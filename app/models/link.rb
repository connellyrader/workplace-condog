# app/models/link.rb
class Link < ApplicationRecord
  belongs_to :user
  before_validation :generate_code, on: :create

  has_many :users, foreign_key: :referred_by_link_id
  has_many :link_clicks, dependent: :destroy

  before_validation { self.code = code.to_s.strip }

  validates :code,
    presence: true,
    uniqueness: { case_sensitive: false },
    length: { minimum: 6 },
    format: { with: /\A[A-Za-z0-9_-]+\z/,
              message: "use only letters, numbers, dashes (-), or underscores (_)" }


  validate :code_locked_if_clicked, on: :update

  # full referral URL
  def full_url
    "#{Rails.application.routes.default_url_options[:host]}/invite/#{code}"
  end

  # --- Stats ---
  def clicks        = link_clicks.count
  def unique_clicks = link_clicks.select(:click_uuid).distinct.count
  def signups       = link_clicks.where.not(created_user_id: nil).count
  def trials = users.joins(:subscriptions).distinct.count
  def conversions = Charge.where(customer_id: users.select(:id)).distinct.count(:customer_id)
  def last_click_at = link_clicks.maximum(:created_at)
  def gross_sales   = Charge.where(customer_id: users.select(:id)).sum(:amount)
  def commissions   = Charge.where(affiliate_id: user_id, customer_id: users.select(:id)).sum(:commission)

  private

  def generate_code
    return if code.present?
    loop do
      self.code = SecureRandom.hex(6)
      break unless self.class.exists?(code: code)
    end
  end

  def code_locked_if_clicked
    return unless will_save_change_to_code?
    return unless link_clicks.exists?
    errors.add(:code, "cannot be changed after the link has received clicks")
  end
end
