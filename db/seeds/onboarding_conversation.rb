# db/seeds/onboarding_conversation.rb
# Creates (or refreshes) a dedicated prototype conversation that runs a scripted
# onboarding flow when the user sends messages in it.
#
# The client detects the conversation by its title — "Get started with Clara" —
# and routes messages through a state machine instead of the random dummy
# responses. All other conversations (new or existing) behave normally.
#
# Run:
#   bundle exec rails demo:populate_onboarding_conversation

return unless Rails.env.development?

puts "[onboarding_conversation] Starting..."

DEMO_EMAIL = "demo@example.com".freeze
SCRIPT_TITLE = "Get started with Workplace".freeze

demo_user = User.find_by(email: DEMO_EMAIL)
raise "Demo user (#{DEMO_EMAIL}) not found. Run `rails db:seed` first." unless demo_user

ws = Workspace.find_by(name: DemoData::Generator::DEMO_WORKSPACE_NAME)
raise "Demo Workspace not found. Run `rails demo:generate_daily` first." unless ws

# Find or create the onboarding conversation.
conv = AiChat::Conversation.find_or_initialize_by(
  user_id: demo_user.id,
  workspace_id: ws.id,
  title: SCRIPT_TITLE
)

GREETING = "Hey! I'm your Workplace assistant. What would you like to call me?".freeze

if conv.new_record?
  conv.save!
  puts "[onboarding_conversation] Created new conversation (id=#{conv.id})"
else
  # Wipe any prior messages so the script always starts at state 0.
  conv.messages.delete_all
  conv.update!(last_activity_at: Time.current)
  puts "[onboarding_conversation] Reset existing conversation (id=#{conv.id})"
end

# Seed the assistant greeting so the user sees it immediately when
# they open the conversation (before they've sent anything).
AiChat::Message.create!(
  ai_chat_conversation_id: conv.id,
  role: "assistant",
  content: GREETING
)

puts "[onboarding_conversation] Done. Title: \"#{SCRIPT_TITLE}\""
