# db/seeds/development.rb
# Run with: rails db:seed (loads this when RAILS_ENV=development)
#
# Creates a demo admin user and minimal metrics framework so you can run
# the demo workspace generator and sign in locally without Slack/Teams SSO.

return unless Rails.env.development?

puts "[Development seeds] Setting up local demo environment..."

# ---------------------------------------------------------------------------
# 1. Demo admin user (email/password login)
# ---------------------------------------------------------------------------
DEMO_EMAIL = "demo@example.com"
DEMO_PASSWORD = "demo123"

demo_user = User.find_or_initialize_by(email: DEMO_EMAIL)
if demo_user.new_record?
  demo_user.assign_attributes(
    first_name: "Demo",
    last_name: "User",
    password: DEMO_PASSWORD,
    password_confirmation: DEMO_PASSWORD,
    admin: true,
    auth_provider: "password"
  )
  demo_user.save!
  puts "  Created demo user: #{DEMO_EMAIL} / #{DEMO_PASSWORD}"
else
  demo_user.update!(admin: true, auth_provider: "password")
  puts "  Demo user exists: #{DEMO_EMAIL} (password unchanged)"
end

# ---------------------------------------------------------------------------
# 2. Minimal Model, Metric, Submetric, SignalCategory (for demo:generate_daily)
# ---------------------------------------------------------------------------
if Model.none?
  Model.create!(
    name: "Demo Model",
    status: "pending",
    inference_mode: "async",
    deployment_type: "OpenAI Batch API",
    openai_model: "gpt-4o-mini"
  )
  puts "  Created demo Model"
end

# Remove Culture if it exists (legacy) - delete in order to avoid FK/callback issues
culture = Metric.find_by(name: "Culture")
if culture
  sc_ids = SignalCategory.joins(:submetric).where(submetrics: { metric_id: culture.id }).pluck(:id)
  submetric_ids = culture.submetrics.pluck(:id)
  Detection.where(signal_category_id: sc_ids).delete_all
  ModelTestDetection.where(signal_category_id: sc_ids).delete_all
  ClaraOverview.where(metric_id: culture.id).delete_all
  Insight.where(metric_id: culture.id).delete_all
  SignalCategory.where(submetric_id: submetric_ids).delete_all
  Submetric.where(metric_id: culture.id).delete_all
  culture.delete
end

# 6 metrics with 3 submetrics each; each submetric has 1 signal category
METRICS_CONFIG = {
  "Employee Engagement" => {
    short_description: "Energy and ownership exhibited in daily activities",
    submetrics: [
      { name: "Sense of Purpose", signal: "Goal clarity", desc: "Clarity of goals and meaning in work" },
      { name: "Connection", signal: "Team bonding", desc: "Quality of relationships and belonging" },
      { name: "Growth", signal: "Learning opportunities", desc: "Opportunities for development" }
    ]
  },
  "Alignment" => {
    short_description: "Shared understanding of goals and priorities",
    submetrics: [
      { name: "Goal Clarity", signal: "Objective alignment", desc: "Understanding of shared objectives" },
      { name: "Shared Priorities", signal: "Priority consensus", desc: "Agreement on what matters most" },
      { name: "Strategy Understanding", signal: "Strategic awareness", desc: "Understanding of direction" }
    ]
  },
  "Psychological Safety" => {
    short_description: "Trust that vulnerability won't be punished",
    submetrics: [
      { name: "Trust", signal: "Interpersonal trust", desc: "Trust between team members" },
      { name: "Voice", signal: "Speaking up", desc: "Comfort sharing ideas and concerns" },
      { name: "Risk-taking", signal: "Safe experimentation", desc: "Willingness to try new things" }
    ]
  },
  "Execution Risk" => {
    short_description: "Measurement of obstacles that might derail productivity",
    submetrics: [
      { name: "Resource Gaps", signal: "Resource constraints", desc: "Adequacy of resources" },
      { name: "Timeline Pressure", signal: "Deadline stress", desc: "Time and deadline pressure" },
      { name: "Dependencies", signal: "Blocking factors", desc: "External blockers and dependencies" }
    ]
  },
  "Conflict" => {
    short_description: "Strains in collaboration and cooperation",
    submetrics: [
      { name: "Interpersonal Tension", signal: "Team friction", desc: "Tension between individuals" },
      { name: "Communication Breakdown", signal: "Miscommunication", desc: "Communication failures" },
      { name: "Competing Priorities", signal: "Priority conflict", desc: "Conflicting priorities" }
    ]
  },
  "Burnout" => {
    short_description: "Signs of exhaustion and loss of motivation",
    submetrics: [
      { name: "Overload", signal: "Workload pressure", desc: "Excessive workload signals" },
      { name: "Exhaustion", signal: "Energy depletion", desc: "Physical and mental exhaustion" },
      { name: "Disengagement", signal: "Emotional distance", desc: "Emotional withdrawal" }
    ]
  }
}.freeze

sort_order = 0
METRICS_CONFIG.each do |metric_name, config|
  metric = Metric.find_or_create_by!(name: metric_name)
  attrs = { short_description: config[:short_description] }
  attrs[:sort] = sort_order if metric.sort.nil?
  metric.update!(attrs)
  sort_order += 1

  config[:submetrics].each do |sm|
    submetric = Submetric.find_or_create_by!(metric: metric, name: sm[:name])
    submetric.update!(short_description: sm[:desc]) if sm[:desc]
    SignalCategory.find_or_create_by!(submetric: submetric, name: sm[:signal])
  end
end
puts "  Created 6 metrics with 3 submetrics each"

puts "[Development seeds] Done."
