# Local Dashboard with Dummy Data & Fake Login

Use this guide to spin up a working dashboard locally with dummy data and passwordless login.

## Quick Start

```bash
# 1. Ensure database is set up
bin/rails db:prepare

# 2. Seed demo user + minimal metrics (required for demo generator)
bin/rails db:seed

# 3. Generate demo workspace data (messages, detections, etc.)
bin/rails demo:generate_daily

# 4. Start the server
bin/rails server
```

Then visit **http://localhost:3000/dev/login?email=demo@example.com** to sign in instantly (no password).

## Credentials

| Login Method | Email | Password |
|-------------|-------|----------|
| Fake login (dev only) | `demo@example.com` | N/A — just visit the URL above |
| Email/password | `demo@example.com` | `demo123` |

## What You Get

- **Demo user** — Admin account with email/password auth
- **Demo Workspace** — Pre-populated with 50 fake users, 6 function channels, messages, and detections
- **Dashboard** — Full metrics, gauge, sparklines, and signals

## Regenerating Demo Data

To refresh the demo workspace with new data for today:

```bash
bin/rails demo:generate_daily
```

To generate data for a specific date:

```bash
DATE=2025-03-01 bin/rails demo:generate_daily
```

## Notes

- The `/dev/login` route **only works in development** and returns 404 in production.
- The demo workspace is read-only; you can explore but not persist changes.
- AI chat in the demo workspace is cleared nightly by the `demo:generate_daily` task.
