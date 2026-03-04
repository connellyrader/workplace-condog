class PartnerMailer < PostmarkTemplatedMailer
  def account_access(user:, password:)
    return unless user&.email.present?

    self.template_model = base_template_model.merge(
      name: (user.respond_to?(:full_name) && user.full_name.present?) ? user.full_name : user.email,
      email: user.email,
      temporary_password: password.to_s,
      action_url: "https://app.workplace.io/partner/sign_in",
      support_email: ApplicationMailer::SUPPORT_EMAIL
    )

    mail(
      to: user.email,
      postmark_template_alias: "partner-account-access"
    )
  end
end
