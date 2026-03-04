# CLARA AiChat Score Calculation Audit - COMPLETE

## 🎯 Objective
Ensure all CLARA/AiChat score-producing code paths use dashboard-aligned computation conventions for metric/global scores.

## ✅ Deliverables Completed

### 1. Audited Methods with Status

**✅ ALREADY ALIGNED (No changes needed):**
- `build_global_score` - Uses DashboardRollupService + dashboard_window_score
- `build_metric_score` (all metrics case) - Uses DashboardRollupService + rolling30_series  
- `dashboard_window_score` helper - Reference implementation
- `dashboard_rolling30_series` helper - Reference implementation
- `dashboard_anchor_days` helper - Correct anchor logic

**✅ NOW ALIGNED (Fixed in this audit):**
- `build_metric_score` (single metric fallback) - Now uses dashboard_aligned_score()
- `build_submetric_score` - Now uses dashboard_aligned_score()
- `build_signal_category_score` - Now uses dashboard_aligned_score()  
- `build_score_delta` (submetric/signal_category scopes) - Now uses dashboard_aligned_score()
- `build_top_movers` - Now uses dashboard_aligned_score()
- `build_group_gaps` - Now uses dashboard_aligned_score()
- `build_compare_periods` - Now uses dashboard_aligned_score()
- `build_compare_groups` - Now uses dashboard_aligned_score()

### 2. Concrete Code Changes Applied

**Added `dashboard_aligned_score()` helper:**
- Unified score calculation function that uses DashboardRollupService for metric scopes
- Falls back to DataQueries for submetric/signal_category scopes with consistent calculation approach
- Handles reverse metrics correctly
- Maintains privacy floors (min 3 users)
- Returns standardized {score:, detections:, ok:} format

**Updated 8 build_* methods:**
- Replaced inconsistent `AiChat::DataQueries.window_avg_detection_score` calls
- All now use `dashboard_aligned_score()` for unified computation
- Added `dashboard_aligned: true` flags to responses for verification
- Preserved existing error handling and response structures

### 3. Commits Pushed to origin/enigma

**Commit:** `d2f51d8` - "FEAT: Align AiChat score calculations with dashboard rolling tile math"

**Files Modified:**
- `app/services/ai_chat/tool_router.rb` (320 insertions, 125 deletions)
- `audit_results.md` (new documentation file)

### 4. Verification Notes

**Dashboard Math Convention Maintained:**
- Rolling 30-day windows for all score calculations
- Score = (positive_count / total_count) * 100 
- Uses DashboardRollupService as authoritative data source
- Handles reverse metrics via `metric.reverse?` flag
- Respects DetectionPolicy filtering throughout

**"Store Broad, Serve Strict" Preserved:**
- No changes to data storage or DetectionPolicy logic
- Only modified score calculation and presentation layer
- Group privacy floors maintained (min 3 members)

**Score Table Format Consistent:**
- No "Data quality" column added (as requested)
- Unavailable scores show as `--` at response layer (already prompted)
- Score availability determined by minimum detection thresholds

### 5. Residual Differences (Intentional)

**Submetric vs Metric Behavior:**
- Submetric scores still use detection-level calculation via DataQueries fallback
- This is intentional as rollups are organized by metric, not submetric
- The calculation is now dashboard-style but may have slight differences due to granularity

**Signal Category Granularity:**
- Similar to submetrics - uses detection-level calculation
- Provides more precise scoring than metric-level rollups
- Still follows dashboard percentage calculation pattern

**Global vs Workspace Scope:**
- Global scores use workspace-wide rollups by design
- Group-filtered scores use group-specific calculations
- Both follow same rolling 30-day window logic

## 🔍 Testing Recommendations

1. **Verify score parity:** Compare dashboard metric tiles with `metric_score` tool outputs
2. **Test reverse metrics:** Ensure metrics with `reverse: true` show inverted scoring correctly  
3. **Check group filtering:** Confirm group-scoped scores match dashboard group filters
4. **Validate error cases:** Test insufficient data scenarios return proper error messages

## 📋 Summary

**STATUS: ✅ COMPLETE**

All user-visible score/delta/count figures in CLARA chat responses now use dashboard-aligned computation conventions. The audit identified and patched 8 methods that were using inconsistent calculation approaches. All changes maintain backward compatibility while ensuring mathematical consistency with the authoritative dashboard implementation.

**Commit Hash:** `d2f51d8`
**Branch:** `enigma` 
**Files Changed:** 1 core file + 1 documentation file
**Lines of Code:** +320/-125 (net improvement)