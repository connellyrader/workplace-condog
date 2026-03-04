# app/mailers/workplace_mailer.rb
class WorkplaceMailer < PostmarkTemplatedMailer
  def welcome(workspace:)
    owner = workspace&.owner
    return unless owner&.email.present?

    self.template_model = base_template_model.merge(
      name: display_name(owner),
      action_url: dashboard_url_for(workspace)
    )

    mail(
      to: owner.email,
      postmark_template_alias: "welcome"
    )
  end

  def invite_accepted(invite:)
    recipient = invite&.invited_by || invite&.workspace&.owner
    return unless recipient&.email.present?

    self.template_model = base_template_model.merge(
      name: display_name(recipient),
      invitee_name: invitee_name_for(invite),
      workspace_name: invite&.workspace&.name.to_s,
      action_url: dashboard_url_for(invite&.workspace)
    )

    mail(
      to: recipient.email,
      postmark_template_alias: "welcome-2"
    )
  end

  def invite_declined(invite:)
    recipient = invite&.invited_by || invite&.workspace&.owner
    return unless recipient&.email.present?

    self.template_model = base_template_model.merge(
      name: display_name(recipient),
      invitee_name: invitee_name_for(invite),
      workspace_name: invite&.workspace&.name.to_s,
      action_url: dashboard_url_for(invite&.workspace)
    )

    mail(
      to: recipient.email,
      postmark_template_alias: "welcome-3"
    )
  end

  def receipt(workspace:, invoice:)
    owner = workspace&.owner
    return unless owner&.email.present?
    return unless invoice

    self.template_model = base_template_model.merge(
      name: display_name(owner),
      receipt_id: receipt_id_for(invoice),
      date: format_timestamp(invoice["created"]),
      receipt_details: receipt_lines(invoice),
      total: format_amount(invoice["total"], invoice["currency"]),
      credit_card_statement_name: credit_card_statement_name(invoice),
      billing_url: billing_url_for(workspace),
      action_url: invoice_pdf_url(invoice)
    )

    mail(
      to: owner.email,
      postmark_template_alias: "receipt"
    )
  end

  def receipt_upcoming(workspace:, billing_date:, amount_cents:, currency:, description:, receipt_id:)
    owner = workspace&.owner
    return unless owner&.email.present?

    self.template_model = base_template_model.merge(
      name: display_name(owner),
      billing_date: format_timestamp(billing_date, default_time: billing_date),
      receipt_id: receipt_id.to_s,
      date: format_timestamp(Time.current),
      receipt_details: [
        {
          description: description.to_s,
          amount: format_amount(amount_cents, currency)
        }
      ],
      total: format_amount(amount_cents, currency),
      credit_card_statement_name: ApplicationMailer::PRODUCT_NAME,
      billing_url: billing_url_for(workspace)
    )

    mail(
      to: owner.email,
      postmark_template_alias: "receipt-1"
    )
  end

  def teams_admin_approved(user:)
    return unless user&.email.present?

    self.template_model = base_template_model.merge(
      name: display_name(user),
      action_url: integrations_url_for(user)
    )

    mail(
      to: user.email,
      postmark_template_alias: "teams-admin-approved"
    )
  end

  def partner_new_customer(partner:, customer:, amount_cents:, currency:, subscription: nil)
    return unless partner&.email.present?

    self.template_model = base_template_model.merge(
      name: display_name(partner),
      customer_name: display_name(customer),
      workspace_name: subscription&.workspace&.name.to_s.presence || customer&.email.to_s,
      amount: format_amount(amount_cents, currency),
      action_url: partner_dashboard_url_for,
      support_email: ApplicationMailer::SUPPORT_EMAIL
    )

    mail(
      to: partner.email,
      postmark_template_alias: "partner-new-customer"
    )
  end

  def partner_refund(partner:, customer:, amount_cents:, currency:, reason: nil)
    return unless partner&.email.present?

    self.template_model = base_template_model.merge(
      name: display_name(partner),
      customer_name: display_name(customer),
      refund_amount: format_amount(amount_cents, currency),
      refund_reason: reason.to_s.presence || "Refund processed",
      action_url: partner_dashboard_url_for,
      support_email: ApplicationMailer::SUPPORT_EMAIL
    )

    mail(
      to: partner.email,
      postmark_template_alias: "partner-refund"
    )
  end

  def dashboard_ready(workspace:)
    owner = workspace&.owner
    return unless owner&.email.present?

    self.template_model = base_template_model.merge(
      name: display_name(owner),
      action_url: dashboard_url_for(workspace),
      support_email: ApplicationMailer::SUPPORT_EMAIL
    )

    mail(
      to: owner.email,
      postmark_template_alias: "welcome-1"
    )
  end

  def workspace_invite(invite:, token:)
    self.template_model = workspace_invite_model(invite, token)

    mail(
      to: invite.email,
      postmark_template_alias: "workspace-invite"
    )
  end

  private

  def workspace_invite_model(invite, token)
    inviter = invite.invited_by
    inviter_name =
      if inviter.respond_to?(:full_name) && inviter.full_name.present?
        inviter.full_name
      else
        inviter&.email.to_s
      end

    base_template_model.merge(
      name: invite.name.presence || invite.email,
      workspace_name: invite.workspace&.name.to_s,
      inviter_name: inviter_name,
      action_url: invite_url(token),
      expires_at: invite.expires_at&.in_time_zone&.strftime("%B %-d, %Y at %-I:%M %p %Z").to_s
    )
  end

  def dashboard_url_for(_workspace)
    url_helpers = Rails.application.routes.url_helpers
    host = Rails.application.routes.default_url_options[:host] || ENV["APP_HOST"]

    if host.present?
      url_helpers.dashboard_url(host: host)
    else
      url_helpers.dashboard_url
    end
  rescue
    url_helpers.root_url
  end

  def billing_url_for(_workspace)
    url_helpers = Rails.application.routes.url_helpers
    host = Rails.application.routes.default_url_options[:host] || ENV["APP_HOST"]

    if host.present?
      url_helpers.billing_url(host: host)
    else
      url_helpers.billing_url
    end
  rescue
    url_helpers.root_url
  end

  def integrations_url_for(_user)
    url_helpers = Rails.application.routes.url_helpers
    host = Rails.application.routes.default_url_options[:host] || ENV["APP_HOST"]

    if host.present?
      url_helpers.integrations_url(host: host)
    else
      url_helpers.integrations_url
    end
  rescue
    url_helpers.root_url
  end

  def partner_dashboard_url_for
    url_helpers = Rails.application.routes.url_helpers
    host = Rails.application.routes.default_url_options[:host] || ENV["APP_HOST"]

    if host.present?
      url_helpers.partner_dashboard_url(host: host)
    else
      url_helpers.partner_dashboard_url
    end
  rescue
    url_helpers.root_url
  end

  def invoice_pdf_url(invoice)
    pdf = invoice.respond_to?(:[]) ? invoice["invoice_pdf"].presence : nil
    hosted = invoice.respond_to?(:[]) ? invoice["hosted_invoice_url"].presence : nil
    pdf || hosted || billing_url_for(nil)
  end

  def receipt_lines(invoice)
    lines = invoice.respond_to?(:[]) ? invoice["lines"] : nil
    data = lines.respond_to?(:[]) ? lines["data"] : nil
    Array(data).map do |line|
      {
        description: line_description(line),
        amount: format_amount(line["amount"], line["currency"] || invoice["currency"])
      }
    end
  end

  def line_description(line)
    return "" unless line.respond_to?(:[])
    line["description"].presence ||
      line.dig("price", "nickname").presence ||
      line.dig("price", "product").presence ||
      "Subscription charge"
  end

  def receipt_id_for(invoice)
    return "" unless invoice.respond_to?(:[])
    invoice["number"].presence || invoice["id"].to_s
  end

  def format_timestamp(epoch_seconds, default_time: nil)
    return "" if epoch_seconds.nil? && default_time.nil?

    time =
      if epoch_seconds.respond_to?(:to_time)
        epoch_seconds.to_time
      elsif epoch_seconds
        Time.at(epoch_seconds.to_i)
      elsif default_time
        default_time
      end

    time.in_time_zone.strftime("%B %-d, %Y")
  rescue
    ""
  end

  def format_amount(cents, currency)
    cur = (currency || "USD").to_s.upcase
    amount = cents.to_i / 100.0
    formatted = format("%.2f", amount)
    cur == "USD" ? "$#{formatted}" : "#{cur} #{formatted}"
  rescue
    cents.to_s
  end

  def credit_card_statement_name(invoice)
    return ApplicationMailer::PRODUCT_NAME unless invoice.respond_to?(:[])
    invoice["account_name"].presence ||
      invoice["statement_descriptor"].presence ||
      ApplicationMailer::PRODUCT_NAME
  end

  def invitee_name_for(invite)
    return "" unless invite

    [invite.name, invite.integration_user&.real_name, invite.email, invite.integration_user&.email]
      .map { |v| v.to_s.strip }
      .reject(&:blank?)
      .first
  end
end
