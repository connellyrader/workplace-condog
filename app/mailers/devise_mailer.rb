# app/mailers/devise_mailer.rb
class DeviseMailer < PostmarkTemplatedMailer
  include Devise::Controllers::UrlHelpers

  def reset_password_instructions(record, token, opts = {})
    self.template_model = password_reset_model(record, token)

    headers = scrub_postmark_read_only_headers(opts).reverse_merge(
      to: record.email,
      postmark_template_alias: "password-reset"
    )

    mail(headers)
  end

  private

  def password_reset_model(record, token)
    base_template_model.merge(
      name: display_name(record),
      action_url: edit_user_password_url(reset_password_token: token)
    )
  end
end
