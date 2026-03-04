# app/mailers/postmark_templated_mailer.rb
class PostmarkTemplatedMailer < ActionMailer::Base
  include PostmarkRails::TemplatedMailerMixin

  default from: ApplicationMailer::DEFAULT_FROM
  layout false # important: do not use Rails mailer layouts for Postmark templates

  private

  def base_template_model
    {
      product_name: ApplicationMailer::PRODUCT_NAME,
      product_year: Time.zone.now.year,
      support_url: ApplicationMailer::SUPPORT_URL,
      support_email: ApplicationMailer::SUPPORT_EMAIL,
      company_name: ApplicationMailer::COMPANY_NAME,
      company_address: ApplicationMailer::COMPANY_ADDRESS
    }
  end

  def display_name(record)
    return record.name if record.respond_to?(:name) && record.name.present?
    record.email
  end

  # Prevent safe_headers violations. These keys are explicitly read-only. :contentReference[oaicite:2]{index=2}
  def scrub_postmark_read_only_headers(hash)
    h = (hash || {}).to_h.dup
    %i[body subject content_type].each { |k| h.delete(k); h.delete(k.to_s) }
    h
  end
end
