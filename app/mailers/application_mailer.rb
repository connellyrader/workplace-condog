# app/mailers/application_mailer.rb
class ApplicationMailer < ActionMailer::Base
  # --- Static defaults (no ENV) ---
  DEFAULT_FROM     = "Workplace.io <noreply@email.workplace.io>".freeze
  PRODUCT_NAME     = "Workplace.io".freeze
  SUPPORT_URL      = "https://support.workplace.io".freeze
  SUPPORT_EMAIL    = (ENV["SUPPORT_EMAIL"] || "support@workplace.io").freeze
  COMPANY_NAME     = "5 Voices Inc.".freeze
  COMPANY_ADDRESS  = "42 Broadway Suite 12-461, New York, NY 10004".freeze

  default from: DEFAULT_FROM
  layout "mailer" # keep for any non-Postmark-template emails

  private

  def base_template_model
    {
      product_name: PRODUCT_NAME,
      product_year: Time.zone.now.year,
      support_url: SUPPORT_URL,
      support_email: SUPPORT_EMAIL,
      company_name: COMPANY_NAME,
      company_address: COMPANY_ADDRESS
    }
  end

  def display_name(record)
    return record.name if record.respond_to?(:name) && record.name.present?
    record.email
  end
end
