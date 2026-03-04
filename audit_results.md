# AiChat Score Calculation Audit Results

## Audited Methods Status

### ✅ ALIGNED (Already using dashboard math):
- `build_global_score` - Uses DashboardRollupService and dashboard_window_score
- `build_metric_score` (all metrics case) - Uses DashboardRollupService with rolling30_series
- `build_score_delta` (global/metric scopes) - Uses DashboardRollupService
- `dashboard_window_score` helper - Correctly implements dashboard logic
- `dashboard_rolling30_series` helper - Reference implementation
- `dashboard_anchor_days` helper - Correct anchor point calculation

### ❌ NOT ALIGNED (Need fixes):
- `build_metric_score` (single metric, V2 fallback) - Uses DataQueries.window_avg_detection_score
- `build_submetric_score` - Uses DataQueries.window_avg_detection_score  
- `build_signal_category_score` - Uses DataQueries.window_avg_detection_score
- `build_score_delta` (submetric/signal_category scopes) - Uses DataQueries.window_avg_detection_score
- `build_top_movers` - Uses DataQueries.window_avg_detection_score
- `build_group_gaps` - Uses DataQueries.window_avg_detection_score
- `build_compare_periods` - Uses DataQueries.window_avg_detection_score
- `build_compare_groups` - Uses DataQueries.window_avg_detection_score
- `build_trend_series` - Uses DataQueries.timeseries (not score-focused but related)

## Issues Identified:

1. **Score calculation inconsistency**: Methods using DataQueries.window_avg_detection_score calculate simple averages of detection scores vs. dashboard's (positive_count / total_count) * 100

2. **Missing dashboard service integration**: Most methods don't use DashboardRollupService which is the authoritative data source

3. **Reverse metric handling gaps**: Not consistently applied across all score calculation paths

4. **Window definition misalignment**: Some methods use arbitrary windows vs. dashboard's rolling 30-day standard

## Changes Needed:

1. **Create dashboard-aligned score calculation helpers** that all methods can use
2. **Extend DashboardRollupService** to support submetric and signal_category scopes
3. **Update all build_* methods** to use consistent score calculation logic
4. **Ensure reverse metric handling** is applied everywhere
5. **Add proper fallback logic** when rollups are unavailable