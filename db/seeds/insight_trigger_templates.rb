# db/seeds/insight_trigger_templates.rb
#
# Seed InsightTriggerTemplate records for the Insights Engine.
#
# IMPORTANT SCOPE RULE:
# - subject_scopes MUST be exactly one of: "user", "group", "admin"
# - "admin" is ONLY used for the "exec_summary" trigger
#
# Assumes model: InsightTriggerTemplate with columns:
# key, driver_type, name, description,
# subject_scopes, dimension_type, direction, primary,
# window_days, baseline_days, window_offset_days,
# min_window_detections, min_baseline_detections,
# min_current_rate, min_delta_rate, min_z_score, severity_weight,
# cooldown_days, max_per_subject_per_window,
# (legacy description columns removed)
# system_prompt, metadata (jsonb)
#
# Adjust names if your model/table is different.

DEFAULT_TRIGGER_METADATA = {
  "min_window_expected_fraction" => 0.35,
  "min_window_floor" => 2,
  "min_baseline_floor" => 6,
  "adaptive_windows" => false
}.freeze

puts "[InsightTriggerTemplate seeds] Seeding canonical templates (non-redundant)…"

def upsert_trigger!(attrs, &block)
  t = InsightTriggerTemplate.find_or_initialize_by(key: attrs[:key])

  t.driver_type                = attrs[:driver_type] || attrs[:key]
  t.name                       = attrs[:name]
  t.description                = attrs[:description]
  t.subject_scopes             = attrs[:subject_scopes] # MUST be "user"|"group"|"admin"
  t.dimension_type             = attrs[:dimension_type]
  t.direction                  = attrs[:direction]
  t.primary                    = attrs.fetch(:primary, true)

  t.window_days                = attrs[:window_days]
  t.baseline_days              = attrs[:baseline_days]
  t.window_offset_days         = attrs.fetch(:window_offset_days, 0)

  t.min_window_detections      = attrs[:min_window_detections]
  t.min_baseline_detections    = attrs[:min_baseline_detections]
  t.min_current_rate           = attrs[:min_current_rate]
  t.min_delta_rate             = attrs[:min_delta_rate]
  t.min_z_score                = attrs[:min_z_score]

  t.severity_weight            = attrs[:severity_weight]
  t.cooldown_days              = attrs[:cooldown_days]
  t.max_per_subject_per_window = attrs[:max_per_subject_per_window]

  t.system_prompt              = attrs[:system_prompt]
  existing_metadata            = (t.metadata || {}).compact
  new_metadata                 = (attrs[:metadata] || {}).compact
  t.metadata                   = DEFAULT_TRIGGER_METADATA.merge(existing_metadata).merge(new_metadata)

  t.enabled                    = attrs.fetch(:enabled, true) if t.respond_to?(:enabled)

  block&.call(t)
  t.save!

  t
end

# -------------------------------------------------------------------
# Coaching prompt scaffolds (kept consistent across triggers)
# -------------------------------------------------------------------

USER_COACHING_HEADER = <<~PROMPT
  You are CLARA, a practical workplace coach.
  You receive ONE JSON object with fields like:
  entity_label, trigger_level, trigger_name, window_days, baseline_days,
  rates/deltas/counts, drivers (submetrics/categories), and PII-scrubbed message snippets
  (timestamp, sender_role, channel_type, text). Messages may be incomplete.

  Audience & voice (USER scope):
  - Write as a direct 1:1 conversation with the user, using “you”.
  - Be supportive, calm, and action-oriented.
  - Do NOT diagnose, label, or speculate about personal circumstances.
  - Never expose scoring, thresholds, model names, or internal mechanics.
  - Never include PII or direct quotes; paraphrase themes only.

  Output format:
  - 1 short headline sentence.
  - 2–4 sentences of context (what changed + what it likely reflects).
  - 3–5 plain-text bullets of next steps the person can try this week (small, concrete, doable).
PROMPT

GROUP_COACHING_HEADER = <<~PROMPT
  You are CLARA, a practical workplace coach.
  You receive ONE JSON object with fields like:
  entity_label, trigger_level, trigger_name, window_days, baseline_days,
  rates/deltas/counts, org comparisons (if any), drivers (submetrics/categories),
  and PII-scrubbed message snippets (timestamp, sender_role, channel_type, text).

  Audience & voice (GROUP scope):
  - Write as if this is being sent to each member of the group (use “you all” / “your team”).
  - Be constructive and non-blaming; focus on practices and environment, not people.
  - Never expose scoring, thresholds, model names, or internal mechanics.
  - Never include PII or direct quotes; paraphrase themes only.

  Output format:
  - 1 short headline sentence.
  - 2–4 sentences of context (what changed + where it seems concentrated).
  - 3–5 plain-text bullets with team-level actions (cadence, clarity, norms, feedback loops).
PROMPT

ADMIN_COACHING_HEADER = <<~PROMPT
  You are CLARA, a practical workplace coach to senior leaders.
  You receive ONE JSON object containing aggregated culture insights for an organization:
  metric trends, biggest risks, biggest improvements, group hotspots, group bright spots,
  and supporting drivers/themes. All inputs are PII-scrubbed.

  Audience & voice (ADMIN scope):
  - Write for an executive leader/admin audience: crisp, action-oriented, non-alarmist.
  - Never expose scoring, thresholds, model names, or internal mechanics.
  - Never include PII or direct quotes; paraphrase themes only.

  Output format:
  - 1 headline sentence.
  - 4–8 bullet summary of key takeaways (risks + improvements).
  - 3–6 bullet “recommended focus actions” for the next 2–4 weeks.
PROMPT

# -------------------------------------------------------------------
# PRIMARY: Metric Trend Shift (User/Group)
# -------------------------------------------------------------------

upsert_trigger!(
  key:                        "metric_negative_rate_spike_user",
  driver_type:                "metric_negative_rate_spike",
  name:                       "Metric trend shift: negative (user)",
  description:                "User-level: negative signals for a metric increased meaningfully vs the user’s baseline.",
  subject_scopes:             "user",
  dimension_type:             "metric",
  direction:                  "negative",
  primary:                    true,
  window_days:                14,
  baseline_days:              60,
  min_window_detections:      8,
  min_baseline_detections:    15,
  min_current_rate:           0.40,
  min_delta_rate:             0.12,
  min_z_score:                nil,
  severity_weight:            1.10,
  cooldown_days:              2,
  max_per_subject_per_window: 1,
  system_prompt: <<~PROMPT,
    #{USER_COACHING_HEADER}

    Task (metric negative trend shift):
    - Explain that this metric has been more negative than usual in the last %{window_days} days compared to baseline.
    - Mention the change using plain language; use counts/rates if provided.
    - Name the top 1–3 drivers (submetrics/categories) as themes.
    - Provide next steps focused on: clarifying priorities, reducing friction, setting boundaries, asking for alignment, and seeking support.
  PROMPT
  metadata: {
    "family"      => "trend_shift",
    "role"        => "primary",
    "scope"       => "user",
    "llm_tone"    => "supportive",
    "insight_kind"=> "risk_spike",
    "adaptive_windows" => true
  }
)

upsert_trigger!(
  key:                        "metric_negative_rate_spike_group",
  driver_type:                "metric_negative_rate_spike",
  name:                       "Metric trend shift: negative (group)",
  description:                "Group-level: negative signals for a metric increased meaningfully vs the group’s baseline.",
  subject_scopes:             "group",
  dimension_type:             "metric",
  direction:                  "negative",
  primary:                    true,
  window_days:                14,
  baseline_days:              60,
  min_window_detections:      25,
  min_baseline_detections:    80,
  min_current_rate:           0.42,
  min_delta_rate:             0.14,
  min_z_score:                nil,
  severity_weight:            1.20,
  cooldown_days:              1,
  max_per_subject_per_window: 1,
  system_prompt: <<~PROMPT,
    #{GROUP_COACHING_HEADER}

    Task (metric negative trend shift):
    - Explain that this team’s signals for %{metric_name} have become more negative in the last %{window_days} days vs baseline.
    - Call out where it’s concentrated (top drivers) and what it might indicate about the team environment.
    - Recommend small team-level experiments: clarify priorities/owners, tighten decision-making, adjust workload pacing, improve expectations, and close feedback loops.
  PROMPT
  metadata: {
    "family"      => "trend_shift",
    "role"        => "primary",
    "scope"       => "group",
    "llm_tone"    => "constructive",
    "insight_kind"=> "risk_spike",
    "adaptive_windows" => true,
    "min_effect_z" => 2.0,
    "max_effect_p" => 0.05
  }
)

upsert_trigger!(
  key:                        "metric_positive_rate_spike_user",
  driver_type:                "metric_positive_rate_spike",
  name:                       "Metric trend shift: positive (user)",
  description:                "User-level: positive signals for a metric increased meaningfully vs the user’s baseline.",
  subject_scopes:             "user",
  dimension_type:             "metric",
  direction:                  "positive",
  primary:                    true,
  window_days:                14,
  baseline_days:              60,
  min_window_detections:      8,
  min_baseline_detections:    15,
  min_current_rate:           0.40,
  min_delta_rate:             0.12,
  min_z_score:                nil,
  severity_weight:            0.90,
  cooldown_days:              2,
  max_per_subject_per_window: 1,
  system_prompt: <<~PROMPT,
    #{USER_COACHING_HEADER}

    Task (metric positive trend shift):
    - Explain that this metric has been more positive than your usual baseline in the last %{window_days} days.
    - Name the top 1–3 positive drivers as themes (what you’re doing / what’s working around you).
    - Provide next steps focused on: protecting time, repeating helpful routines, acknowledging contributors, and sharing what’s working with your team.
  PROMPT
  metadata: {
    "family"      => "trend_shift",
    "role"        => "primary",
    "scope"       => "user",
    "llm_tone"    => "encouraging",
    "insight_kind"=> "improvement",
    "adaptive_windows" => true
  }
)

upsert_trigger!(
  key:                        "metric_positive_rate_spike_group",
  driver_type:                "metric_positive_rate_spike",
  name:                       "Metric trend shift: positive (group)",
  description:                "Group-level: positive signals for a metric increased meaningfully vs the group’s baseline.",
  subject_scopes:             "group",
  dimension_type:             "metric",
  direction:                  "positive",
  primary:                    true,
  window_days:                14,
  baseline_days:              60,
  min_window_detections:      25,
  min_baseline_detections:    80,
  min_current_rate:           0.42,
  min_delta_rate:             0.14,
  min_z_score:                nil,
  severity_weight:            1.00,
  cooldown_days:              1,
  max_per_subject_per_window: 1,
  system_prompt: <<~PROMPT,
    #{GROUP_COACHING_HEADER}

    Task (metric positive trend shift):
    - Explain that this team is showing stronger positive signals on %{metric_name} vs baseline.
    - Identify what seems to be working (top drivers/themes).
    - Recommend ways to sustain and scale it: keep the ritual, protect focus time, reinforce norms, and share practices with nearby teams.
  PROMPT
  metadata: {
    "family"      => "trend_shift",
    "role"        => "primary",
    "scope"       => "group",
    "llm_tone"    => "appreciative",
    "insight_kind"=> "improvement",
    "adaptive_windows" => true,
    "min_effect_z" => 2.0,
    "max_effect_p" => 0.05
  }
)

# -------------------------------------------------------------------
# PRIMARY: Chronic Sustained Negative (Group/Workspace)
# -------------------------------------------------------------------

upsert_trigger!(
  key:                        "metric_sustained_negative_rate_group",
  driver_type:                "metric_sustained_negative_rate",
  name:                       "Chronic sustained negative (group)",
  description:                "Group-level: negative signals remain elevated over a sustained window.",
  subject_scopes:             "group",
  dimension_type:             "metric",
  direction:                  "negative",
  primary:                    true,
  window_days:                30,
  baseline_days:              60,
  min_window_detections:      12,
  min_baseline_detections:    0,
  min_current_rate:           0.50,
  min_delta_rate:             nil,
  min_z_score:                nil,
  severity_weight:            1.00,
  cooldown_days:              1,
  max_per_subject_per_window: 1,
  system_prompt: <<~PROMPT,
    #{GROUP_COACHING_HEADER}

    Task (chronic sustained negative):
    - Explain that negative signals for %{metric_name} have stayed elevated over the last month.
    - Emphasize persistence rather than a spike; note this may reflect an ongoing blocker or process issue.
    - Recommend team-level triage: identify root cause themes, assign owners, and set a short action plan.
  PROMPT
  metadata: {
    "family"      => "chronic",
    "role"        => "primary",
    "scope"       => "group",
    "llm_tone"    => "practical",
    "insight_kind"=> "risk_spike",
    "adaptive_windows" => true
  }
)

upsert_trigger!(
  key:                        "metric_sustained_negative_rate_workspace",
  driver_type:                "metric_sustained_negative_rate",
  name:                       "Chronic sustained negative (workspace)",
  description:                "Workspace-level: negative signals remain elevated over a sustained window.",
  subject_scopes:             "admin",
  dimension_type:             "metric",
  direction:                  "negative",
  primary:                    true,
  window_days:                30,
  baseline_days:              60,
  min_window_detections:      25,
  min_baseline_detections:    0,
  min_current_rate:           0.45,
  min_delta_rate:             nil,
  min_z_score:                nil,
  severity_weight:            1.00,
  cooldown_days:              1,
  max_per_subject_per_window: 1,
  system_prompt: <<~PROMPT,
    #{GROUP_COACHING_HEADER}

    Task (chronic sustained negative):
    - Explain that negative signals for %{metric_name} have stayed elevated across the org over the last month.
    - Emphasize persistence rather than a spike; note this may reflect an ongoing blocker or process issue.
    - Recommend org-level triage: identify root cause themes, assign owners, and set a short action plan.
  PROMPT
  metadata: {
    "family"      => "chronic",
    "role"        => "primary",
    "scope"       => "workspace",
    "llm_tone"    => "practical",
    "insight_kind"=> "risk_spike",
    "adaptive_windows" => true
  }
)

# -------------------------------------------------------------------
# PRIMARY: Group vs Org (Hotspot / Bright Spot)
# -------------------------------------------------------------------

upsert_trigger!(
  key:                        "group_outlier_vs_org",
  driver_type:                "group_outlier_vs_org",
  name:                       "Group hotspot vs org (negative)",
  description:                "Group-level: this team is meaningfully worse than the org average on a metric in the current window.",
  subject_scopes:             "group",
  dimension_type:             "metric",
  direction:                  "negative",
  primary:                    true,
  window_days:                30,
  baseline_days:              30,
  min_window_detections:      25,
  min_baseline_detections:    25,
  min_current_rate:           0.35,
  min_delta_rate:             0.08,  # group vs org gap (interpretation)
  min_z_score:                1.2,
  severity_weight:            1.25,
  cooldown_days:              1,
  max_per_subject_per_window: 1,
  system_prompt: <<~PROMPT,
    #{GROUP_COACHING_HEADER}

    Task (group hotspot vs org):
    - Explain that this team is showing a larger share of negative signals on %{metric_name} than the org average in the last %{window_days} days.
    - Quantify the gap in plain language if provided (avoid thresholds).
    - Name the leading drivers and propose 3–5 team-level interventions to close the gap (clarity, workload norms, decision hygiene, support, feedback).
  PROMPT
  metadata: {
    "family"      => "hotspot",
    "role"        => "primary",
    "scope"       => "group",
    "llm_tone"    => "constructive",
    "insight_kind"=> "group_hotspot",
    "adaptive_windows" => true
  }
)

upsert_trigger!(
  key:                        "group_bright_spot_vs_org",
  driver_type:                "group_bright_spot_vs_org",
  name:                       "Group bright spot vs org (positive)",
  description:                "Group-level: this team is meaningfully better than the org average on a metric in the current window.",
  subject_scopes:             "group",
  dimension_type:             "metric",
  direction:                  "positive",
  primary:                    true,
  window_days:                30,
  baseline_days:              30,
  min_window_detections:      25,
  min_baseline_detections:    25,
  min_current_rate:           0.45,
  min_delta_rate:             0.08,  # group vs org advantage (interpretation)
  min_z_score:                1.2,
  severity_weight:            1.05,
  cooldown_days:              1,
  max_per_subject_per_window: 1,
  system_prompt: <<~PROMPT,
    #{GROUP_COACHING_HEADER}

    Task (group bright spot vs org):
    - Explain that this team is showing stronger positive signals on %{metric_name} than the org average in the last %{window_days} days.
    - Highlight what seems to be working (drivers/themes).
    - Provide 3–5 ways to protect and spread the practices (document rituals, peer share-out, onboarding norms, lightweight playbook).
  PROMPT
  metadata: {
    "family"                 => "hotspot",
    "role"                   => "primary",
    "scope"                  => "group",
    "llm_tone"               => "appreciative",
    "insight_kind"           => "group_bright_spot",
    "pocket_of_strength_mode"=> true,
    "adaptive_windows" => true
  }
)

# -------------------------------------------------------------------
# PRIMARY: Exec Summary (Admin)
# -------------------------------------------------------------------

upsert_trigger!(
  key:                        "exec_summary",
  driver_type:                "exec_summary",
  name:                       "Executive summary",
  description:                "Admin-level: leadership-facing summary of culture patterns (risks, improvements, hotspots, bright spots) for the current period.",
  subject_scopes:             "admin",
  dimension_type:             "summary",
  direction:                  "both",
  primary:                    true,
  window_days:                30,
  baseline_days:              30,
  min_window_detections:      25,
  min_baseline_detections:    25,
  min_current_rate:           0.0,
  min_delta_rate:             0.0,
  min_z_score:                nil,
  severity_weight:            1.00,
  cooldown_days:              0,
  max_per_subject_per_window: 0,
  system_prompt: <<~PROMPT,
    #{ADMIN_COACHING_HEADER}

    Task (exec summary):
    - Provide a descriptive overview of the current period without citing numbers, rates, or percentages.
    - Summarize key risks and improvements in plain language (no data-heavy lists).
    - Highlight a few group hotspots and bright spots with brief drivers (no blame, no PII).
    - Provide “recommended focus actions” leadership can take in the next 2–4 weeks:
      (1) clarify priorities/decision rights, (2) adjust workload/pace, (3) strengthen comms/feedback loops, (4) remove recurring blockers.
    - Keep it crisp and prioritised; avoid long narrative and avoid numerical detail.
  PROMPT
  metadata: {
    "family"      => "exec",
    "role"        => "primary",
    "scope"       => "admin",
    "llm_tone"    => "executive",
    "insight_kind"=> "exec_summary"
  }
)

# -------------------------------------------------------------------
# HARD CLEANUP: delete any templates not in this canonical set
# -------------------------------------------------------------------

DESIRED_KEYS = %w[
  metric_negative_rate_spike_user
  metric_negative_rate_spike_group
  metric_positive_rate_spike_user
  metric_positive_rate_spike_group

  metric_sustained_negative_rate_group
  metric_sustained_negative_rate_workspace

  group_outlier_vs_org
  group_bright_spot_vs_org

  exec_summary
].freeze

extra = InsightTriggerTemplate.where.not(key: DESIRED_KEYS)
puts "[InsightTriggerTemplate seeds] Removing #{extra.count} unused templates…"
extra.delete_all

puts "[InsightTriggerTemplate seeds] Done."
