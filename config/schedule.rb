# Use this file to easily define all of your cron jobs.
# Learn more: http://github.com/javan/whenever

# LUCAS - to update crontab, run:
#   bundle exec whenever --update-crontab

APP_DIR = "/home/rails/workplace"

# Non-overlapping rake runner using flock.
# If a prior run is still active, the next one exits immediately.
def locked_rake(task_with_args, lock:)
  command %(cd #{APP_DIR} && /usr/bin/flock -n /tmp/workplace-#{lock}.lock /bin/bash -lc 'RAILS_ENV=production bundle exec rake #{task_with_args} --silent')
end

# -------------------------------------------------------------------
# Inference / ingestion cadence (staggered + lock-protected)
# -------------------------------------------------------------------

# 2x per minute attempts (at +5s and +35s), but never overlapping due to flock.
every 1.minute do
  command %(cd #{APP_DIR} && /bin/bash -lc 'sleep 5;  /usr/bin/flock -n /tmp/workplace-aws-process.lock bundle exec rake aws:process_messages[3] --silent')
  command %(cd #{APP_DIR} && /bin/bash -lc 'sleep 35; /usr/bin/flock -n /tmp/workplace-aws-process.lock bundle exec rake aws:process_messages[3] --silent')
end

# Fetch detections every 2 minutes, offset from minute 0.
every '1-59/2 * * * *' do
  locked_rake "aws:fetch_detections[80]", lock: "aws-fetch-detections"
end

# Fetch slack message events from s3 every 2 minutes, offset to avoid bunching.
every '3-59/2 * * * *' do
  locked_rake "slack:fetch_events LIMIT=50", lock: "slack-fetch-events"
end

# -------------------------------------------------------------------
# Backfill / audit cadence (reduced overlap pressure)
# -------------------------------------------------------------------

# Slack backfill every 6 minutes
every '*/6 * * * *' do
  locked_rake "slack:backfill:tick BACKFILL_MAX_PER_TICK=12 BACKFILL_STEP_TIMEOUT_SEC=60 BACKFILL_MAX_PAGES_30D=2 BACKFILL_MAX_PAGES_DEEP=1 BACKFILL_MAX_PER_TEAM_PER_TICK=4", lock: "slack-backfill"
end

# Teams backfill every 6 minutes, offset by 2 minutes
every '2-59/6 * * * *' do
  locked_rake "teams:backfill:tick TEAMS_BACKFILL_MAX_PER_TICK=12 TEAMS_BACKFILL_STEP_TIMEOUT_SEC=180", lock: "teams-backfill"
end

# Teams forward audits every 10 minutes, offset by 5 minutes
every '5-59/10 * * * *' do
  locked_rake "teams:audit:tick TEAMS_AUDIT_MAX_PER_TICK=12 TEAMS_AUDIT_STALE_AFTER_MIN=90 TEAMS_AUDIT_STEP_TIMEOUT_SEC=120", lock: "teams-audit"
end

# Slack forward audit every 10 minutes, offset by 8 minutes
every '8-59/10 * * * *' do
  locked_rake "slack:audit:tick AUDIT_MAX_PER_TICK=60 AUDIT_STALE_AFTER_MIN=45 AUDIT_STEP_TIMEOUT_SEC=60", lock: "slack-audit"
end

# -------------------------------------------------------------------
# Cache / maintenance jobs
# -------------------------------------------------------------------

# Warm dashboard caches less frequently to avoid memory pileups.
# NOTE: scheduler runs on prod1 only.
every 20.minutes do
  locked_rake "dashboard:warm_cache WARM_TOP_WORKSPACES=20 WARM_TOP_GROUPS=3", lock: "dashboard-warm-cache"
end

# Full rollup rebuild (nightly safety net)
every 1.day, at: "2:00 am" do
  locked_rake "rollups:backfill", lock: "rollups-backfill"
end

# Slack resync nightly
every 1.day, at: "2:30 am" do
  locked_rake "slack:resync", lock: "slack-resync"
end

# Optional: nightly Teams directory/channel membership refresh
every 1.day, at: "3:30 am" do
  locked_rake "teams:resync", lock: "teams-resync"
end

# Demo workspace daily data (nightly)
every 1.day, at: "1:30 am" do
  locked_rake "demo:generate_daily", lock: "demo-generate-daily"
end
