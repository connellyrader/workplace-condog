class InsightsMailer < ApplicationMailer
  include PostmarkRails::TemplatedMailerMixin

  after_action :apply_postmark_template

  def insight_notification(recipient:, insight:, action_url: default_action_url(insight))
    @postmark_template_alias = "insight-notification"
    @postmark_template_model = template_model(recipient, insight, action_url)

    mail(
      to: recipient.email,
      postmark_template_alias: @postmark_template_alias
    )
  end

  private

  def apply_postmark_template
    return unless @postmark_template_model

    message.template_model = @postmark_template_model
  end

  def template_model(recipient, insight, action_url)
    {
      name: display_name(recipient),
      product_name: product_name,
      support_url: support_url,
      action_url: action_url,
      insight_title: insight.summary_title.presence || fallback_title(insight),
      insight_body: insight.summary_body.presence || fallback_body(insight),
      workspace_name: insight.workspace&.name
    }
  end

  def display_name(user)
    user&.full_name.presence || user&.name.presence || user&.email
  end

  def fallback_title(insight)
    insight.trigger_template&.name || "New insight"
  end

  def fallback_body(insight)
    insight.data_payload.is_a?(Hash) ? insight.data_payload.to_json : "An insight was generated for your workspace."
  end

  def default_action_url(_insight)
    url_helpers = Rails.application.routes.url_helpers
    host = Rails.application.routes.default_url_options[:host] || ENV["APP_HOST"]
    if host.present?
      url_helpers.root_url(host: host)
    else
      url_helpers.root_url
    end
  rescue
    ENV.fetch("INSIGHT_DASHBOARD_URL", "")
  end

  def product_name
    ENV.fetch("PRODUCT_NAME", "Workplace")
  end

  def support_url
    ENV.fetch("SUPPORT_URL", "https://workplace.io/support")
  end
end
