# db/seeds/demo_account_holders.rb
# Populates the Demo Workspace with fake account-holder users so the
# Admin Users index and Settings > Manage Users pages have data to show.
#
# Run with:  bundle exec rails runner db/seeds/demo_account_holders.rb
# Or from a rake task (see lib/tasks/demo_populate.rake).
#
# Idempotent: re-running updates existing rows and adds any missing ones.

return unless Rails.env.development?

puts "[demo_account_holders] Starting..."

ws = Workspace.find_by(name: DemoData::Generator::DEMO_WORKSPACE_NAME)
raise "Demo Workspace not found. Run `rails demo:generate_daily` first." unless ws

integration = ws.integrations.where(kind: "slack").first
raise "Demo Workspace has no Slack integration." unless integration

# Pool of realistic account holders. Each will map to an existing
# demo IntegrationUser (by order) so the join data works.
#
# status_key options:
#   :data_synced  -> integration_user gets a slack_history_token
#   :partial_data -> integration_user has no token (in group, not connected)
#   :no_data      -> integration_user removed from all groups
#
# role options:
#   "owner" (only one), "admin", "user", "viewer"
#
PEOPLE = [
  { first_name: "Sarah",    last_name: "Chen",      role: "admin",  status: :data_synced  },
  { first_name: "Marcus",   last_name: "Johnson",   role: "admin",  status: :data_synced  },
  { first_name: "Priya",    last_name: "Patel",     role: "user",   status: :data_synced  },
  { first_name: "Alex",     last_name: "Kim",       role: "user",   status: :data_synced  },
  { first_name: "Jordan",   last_name: "Rivera",    role: "user",   status: :partial_data },
  { first_name: "Emma",     last_name: "Wilson",    role: "user",   status: :partial_data },
  { first_name: "Noah",     last_name: "Bennett",   role: "viewer", status: :partial_data },
  { first_name: "Olivia",   last_name: "Martinez",  role: "viewer", status: :no_data      }
].freeze

# Use the existing demo integration_users as the Slack identities for
# these account holders. Order them so the mapping is stable.
integration_users = IntegrationUser.where(integration_id: integration.id).order(:id).to_a

if integration_users.size < PEOPLE.size
  raise "Need at least #{PEOPLE.size} integration_users; found #{integration_users.size}"
end

created_count = 0
updated_count = 0

PEOPLE.each_with_index do |person, idx|
  iu = integration_users[idx]
  email = "#{person[:first_name].downcase}.#{person[:last_name].downcase}@demo.example.com"

  # --- Find or create User -------------------------------------------------
  user = User.find_or_initialize_by(email: email)
  if user.new_record?
    user.assign_attributes(
      first_name: person[:first_name],
      last_name:  person[:last_name],
      password:   "demo123",
      password_confirmation: "demo123",
      auth_provider: "slack"
    )
    user.save!
    created_count += 1
  else
    user.update!(
      first_name: person[:first_name],
      last_name:  person[:last_name],
      auth_provider: "slack"
    )
    updated_count += 1
  end

  # --- Wire up WorkspaceUser ----------------------------------------------
  wu = WorkspaceUser.find_or_initialize_by(workspace_id: ws.id, user_id: user.id)
  wu.role     = person[:role]
  wu.is_owner = (person[:role] == "owner")
  wu.save!

  # --- Link IntegrationUser to this User ----------------------------------
  iu.update!(
    user_id:    user.id,
    real_name:  user.full_name,
    display_name: "#{person[:first_name]}#{person[:last_name][0]}".downcase,
    email:      email
  )

  # --- Set data status via Slack token & group membership -----------------
  case person[:status]
  when :data_synced
    # Give them a fake history token (triggers "Data synced" label)
    iu.update!(slack_history_token: "xoxp-demo-#{SecureRandom.hex(8)}")
    # They keep their group memberships (generator already added them)
  when :partial_data
    # No token. Keep group memberships so they still appear "in group" but only partial.
    iu.update!(slack_history_token: nil)
  when :no_data
    # No token AND remove from all groups -> "No data" status
    iu.update!(slack_history_token: nil)
    GroupMember.where(integration_user_id: iu.id).delete_all
  end
end

puts "[demo_account_holders] Created #{created_count} / Updated #{updated_count} account-holder users"
puts "[demo_account_holders] Total WorkspaceUsers in Demo Workspace: #{ws.workspace_users.count}"
puts "[demo_account_holders] Total Users overall: #{User.count}"
puts "[demo_account_holders] Done."
