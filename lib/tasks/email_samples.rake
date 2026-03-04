namespace :email do
  desc "Send sample Postmark template emails to verify placeholders (set EMAIL=you@example.com)"
  task samples: :environment do
    target = ENV.fetch("EMAIL", "dev@example.com")

    owner     = User.new(email: target, first_name: "Taylor", last_name: "Partner")
    customer  = User.new(email: "customer@example.com", first_name: "Alex", last_name: "Customer")
    partner   = User.new(email: target, first_name: "Pat", last_name: "Ner", partner: true)
    requester = User.new(email: target, first_name: "Morgan", last_name: "Requester")

    workspace = Workspace.new(name: "Acme Workspace", owner: owner)
    subscription = Subscription.new(
      user: customer,
      workspace: workspace,
      interval: "month"
    )

    invite = WorkspaceInvite.new(
      workspace: workspace,
      integration_user: IntegrationUser.new(real_name: "Jamie Invited", email: "jamie@example.com"),
      invited_by: owner,
      email: "jamie@example.com",
      name: "Jamie Invited"
    )

    sample_invoice = {
      "id" => "in_sample123",
      "number" => "INV-001",
      "created" => Time.current.to_i,
      "currency" => "usd",
      "total" => 123_45,
      "account_name" => "Workplace.io",
      "statement_descriptor" => "Workplace.io",
      "invoice_pdf" => "https://example.com/sample_invoice.pdf",
      "hosted_invoice_url" => "https://example.com/invoice",
      "lines" => {
        "data" => [
          { "description" => "Pro plan (monthly)", "amount" => 100_00, "currency" => "usd" },
          { "description" => "Seats x3", "amount" => 23_45, "currency" => "usd" }
        ]
      }
    }

    send_mail = ->(label, mail) do
      mail.deliver_now
      puts "[sent] #{label} → #{mail.to.inspect}"
    rescue => e
      warn "[error] #{label}: #{e.class}: #{e.message}"
    end

    send_mail.call("welcome", WorkplaceMailer.welcome(workspace: workspace))
    send_mail.call("dashboard_ready", WorkplaceMailer.dashboard_ready(workspace: workspace))
    send_mail.call("workspace_invite", WorkplaceMailer.workspace_invite(invite: invite, token: "sample-token"))
    send_mail.call("invite_accepted", WorkplaceMailer.invite_accepted(invite: invite))
    send_mail.call("invite_declined", WorkplaceMailer.invite_declined(invite: invite))
    send_mail.call("receipt", WorkplaceMailer.receipt(workspace: workspace, invoice: sample_invoice))
    send_mail.call(
      "receipt_upcoming",
      WorkplaceMailer.receipt_upcoming(
        workspace: workspace,
        billing_date: 2.weeks.from_now,
        amount_cents: 99_00,
        currency: "usd",
        description: "Pro plan (3 seats)",
        receipt_id: "UPCOMING-123"
      )
    )
    send_mail.call("teams_admin_approved", WorkplaceMailer.teams_admin_approved(user: requester))
    send_mail.call(
      "partner_new_customer",
      WorkplaceMailer.partner_new_customer(
        partner: partner,
        customer: customer,
        amount_cents: 199_00,
        currency: "usd",
        subscription: subscription
      )
    )
    send_mail.call(
      "partner_refund",
      WorkplaceMailer.partner_refund(
        partner: partner,
        customer: customer,
        amount_cents: 50_00,
        currency: "usd",
        reason: "Customer requested refund"
      )
    )
  end
end
