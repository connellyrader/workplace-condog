# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased] - enigma branch

### Fixed - 2026-02-05

#### Dashboard Turbo cache disabled
- Added turbo cache control meta tag for DashboardController pages to prevent Turbo cache on back navigation.
- Force reload on bfcache restore for DashboardController pages to avoid stale session state.

#### Dashboard Group Rollups & Privacy Floor Enforcement

**DashboardRollupService - Use Group rollups for filtered views:**
- `app/services/dashboard_rollup_service.rb`
  - Added `group_id` parameter to constructor
  - New `daily_counts_from_group_rollups()` method - queries Group-level rollups
  - New `counts_by_metric_from_group_rollups()` method
  - Now uses fast rollup queries for group-filtered views instead of falling back to slow detection queries

- `app/controllers/concerns/dashboard_rollups.rb`
  - Pass `@selected_group.id` to DashboardRollupService

**Privacy floor enforcement on Everyone group fallback:**
- `app/controllers/dashboard_controller.rb` (`load_topbar_groups`)
  - Everyone group now checked for >= 3 members before being used as fallback
  - Prevents data leakage when Everyone group has fewer than 3 users

---

### Added - 2026-02-05

#### Multi-Integration Support for Slack Workspaces
One Slack workspace can now feed multiple Workplace integrations.

**Changes:**
- `app/services/slack/event_fetcher.rb`
  - Finds ALL integrations for a team_id (not just most recent)
  - Creates a message record for EACH integration
  - Translation done ONCE, shared across integrations (no extra cost)
  - New `persist_message_for_integration!()` helper with error handling

**Use case:** Customer has one Slack workspace connected to multiple Workplace accounts (different departments, test/prod, etc.)

---

### Added - 2026-02-04

#### Language Detection & Translation System
Free local language detection + GPT translation only when needed.

**New files:**
- `app/services/language/detector.rb` - Local language detection (FREE)
  - Character range detection for CJK, Cyrillic, Arabic, Hebrew, etc.
  - Trigram analysis for Latin-script languages (en, es, fr, de, hu, etc.)
  - Returns language code + confidence score
  
- `app/services/language/translator.rb` - GPT translation service
  - Uses GPT-4o-mini for cost efficiency (~$6/month for 50-person company)
  - Caches translations to avoid repeat API calls
  - Only called for non-English text
  
- `app/services/language/service.rb` - Main entry point
  - `Language::Service.process_for_inference(text)` - full pipeline
  - Returns translated text + metadata (source_lang, was_translated, etc.)

- `lib/tasks/language.rake` - Debug/test rake tasks
  - `rake language:test_detection` - test language detection
  - `rake language:test_translation` - test translation pipeline
  - `rake language:workspace_distribution[id]` - analyze language mix
  - `rake language:detect_message[id]` - detect language for specific message

**Modified:**
- `app/services/inference/message_processor.rb`
  - Integrated language detection + translation before SageMaker inference
  - Tracks translation stats in counters (translated, cached, errors)
  - Logs translations for monitoring

**Cost savings:**
- Language detection: $0 (local, instant)
- Translation: GPT-4o-mini only for non-English (~$6/mo per 50-person company)
- Cache hit rate should be high for repeated phrases

---

### Added - 2026-02-04 (earlier)

#### Privacy Audit
- Removed `integration_user_ids` from 8 tool router methods
- Added `check_privacy_floor()` in DataQueries (enforces min 3 users)
- Signal category minimum now requires >=3 detections
- Documented in `docs/PRIVACY_AUDIT_2026-02-04.md`

#### Group-Level Rollups
- `bulk_increment_for_groups!()` in InsightDetectionRollup
- DetectionFetcher writes rollups at Workspace AND Group level
- `group_score_from_rollups()` and `compare_groups_from_rollups()` for fast queries

#### Bug Fixes
- Fixed GROUP BY error in rollup_builder (literal ID vs position reference)
- Fixed metric page date mismatch (detection counts now show last-30d)
