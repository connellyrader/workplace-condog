# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_06_02_020000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_trgm"
  enable_extension "plpgsql"
  enable_extension "vector"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_chat_conversations", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "title", default: "New conversation", null: false
    t.datetime "last_activity_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "system_prompt"
    t.bigint "workspace_id", null: false
    t.string "purpose"
    t.index ["purpose"], name: "index_ai_chat_conversations_on_purpose"
    t.index ["user_id", "last_activity_at"], name: "index_ai_chat_conversations_on_user_id_and_last_activity_at"
    t.index ["user_id", "purpose", "last_activity_at"], name: "idx_ai_chat_conv_user_purpose_activity"
    t.index ["user_id"], name: "index_ai_chat_conversations_on_user_id"
    t.index ["workspace_id", "user_id", "last_activity_at"], name: "idx_ai_chat_conversations_ws_user_activity"
    t.index ["workspace_id"], name: "index_ai_chat_conversations_on_workspace_id"
  end

  create_table "ai_chat_messages", force: :cascade do |t|
    t.bigint "ai_chat_conversation_id", null: false
    t.string "role", null: false
    t.text "content", null: false
    t.integer "tokens_in"
    t.integer "tokens_out"
    t.jsonb "meta", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "tool_call_count", default: 0, null: false
    t.index ["ai_chat_conversation_id", "created_at"], name: "idx_ai_chat_msg_conv_created"
    t.index ["ai_chat_conversation_id"], name: "idx_ai_chat_msg_conv"
  end

  create_table "apps", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.string "status", default: "future", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_apps_on_name", unique: true
    t.index ["status"], name: "index_apps_on_status"
  end

  create_table "async_inference_results", force: :cascade do |t|
    t.bigint "model_test_id", null: false
    t.bigint "message_id"
    t.string "response_location"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "inference_arn"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.float "duration"
    t.datetime "completed_at"
    t.string "inference_type"
    t.integer "model_test_detection_id"
    t.string "provider"
    t.index ["message_id"], name: "index_async_inference_results_on_message_id"
    t.index ["model_test_id"], name: "index_async_inference_results_on_model_test_id"
  end

  create_table "aws_instances", force: :cascade do |t|
    t.string "instance_type"
    t.float "hourly_price"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "benchmark_labels", force: :cascade do |t|
    t.bigint "benchmark_message_id"
    t.string "label_name", null: false
    t.boolean "is_primary", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "benchmark_message_external_id"
    t.index ["benchmark_message_external_id"], name: "index_benchmark_labels_on_benchmark_message_external_id"
    t.index ["benchmark_message_id", "label_name"], name: "index_benchmark_labels_on_benchmark_message_id_and_label_name", unique: true
    t.index ["benchmark_message_id"], name: "index_benchmark_labels_on_benchmark_message_id"
    t.index ["label_name"], name: "index_benchmark_labels_on_label_name"
  end

  create_table "benchmark_messages", force: :cascade do |t|
    t.string "benchmark_set", default: "golden_rules_v1", null: false
    t.string "external_message_id", null: false
    t.string "label_primary", null: false
    t.string "scenario_id"
    t.text "message_text", null: false
    t.string "style_bucket"
    t.string "length_bucket"
    t.string "variant"
    t.string "source_model"
    t.string "source_provider"
    t.string "source_prompt_version"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["benchmark_set"], name: "index_benchmark_messages_on_benchmark_set"
    t.index ["external_message_id"], name: "index_benchmark_messages_on_external_message_id", unique: true
    t.index ["label_primary"], name: "index_benchmark_messages_on_label_primary"
    t.index ["scenario_id"], name: "index_benchmark_messages_on_scenario_id"
  end

  create_table "benchmark_review_recommendations", force: :cascade do |t|
    t.bigint "benchmark_message_id", null: false
    t.bigint "user_id", null: false
    t.string "label_name", null: false
    t.string "recommendation", null: false
    t.text "notes"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["benchmark_message_id", "user_id", "label_name"], name: "idx_benchmark_review_recs_unique", unique: true
    t.index ["benchmark_message_id"], name: "index_benchmark_review_recommendations_on_benchmark_message_id"
    t.index ["recommendation"], name: "index_benchmark_review_recommendations_on_recommendation"
    t.index ["user_id"], name: "index_benchmark_review_recommendations_on_user_id"
  end

  create_table "benchmark_review_scenario_states", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "benchmark_set", null: false
    t.string "label_primary", null: false
    t.string "scenario_id", null: false
    t.boolean "done", default: false, null: false
    t.text "comment"
    t.datetime "done_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "benchmark_set", "done"], name: "idx_benchmark_review_scenario_states_user_set_done"
    t.index ["user_id", "benchmark_set", "label_primary", "scenario_id"], name: "idx_benchmark_review_scenario_states_unique", unique: true
    t.index ["user_id"], name: "index_benchmark_review_scenario_states_on_user_id"
  end

  create_table "channel_identities", force: :cascade do |t|
    t.bigint "integration_id", null: false
    t.bigint "channel_id", null: false
    t.bigint "integration_user_id"
    t.string "provider", null: false
    t.string "external_channel_id", null: false
    t.datetime "discovered_at"
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_channel_identities_on_channel_id"
    t.index ["integration_id", "provider", "external_channel_id"], name: "idx_channel_identities_on_integration_provider_extid", unique: true
    t.index ["integration_id"], name: "index_channel_identities_on_integration_id"
    t.index ["integration_user_id"], name: "index_channel_identities_on_integration_user_id"
  end

  create_table "channel_memberships", force: :cascade do |t|
    t.bigint "integration_id", null: false
    t.bigint "channel_id", null: false
    t.bigint "integration_user_id", null: false
    t.datetime "joined_at"
    t.datetime "left_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id", "integration_user_id"], name: "idx_on_channel_id_integration_user_id_b522800b12", unique: true
    t.index ["channel_id"], name: "index_channel_memberships_on_channel_id"
    t.index ["integration_id"], name: "index_channel_memberships_on_integration_id"
    t.index ["integration_user_id"], name: "index_channel_memberships_on_integration_user_id"
  end

  create_table "channels", force: :cascade do |t|
    t.bigint "integration_id", null: false
    t.string "external_channel_id"
    t.string "name"
    t.boolean "is_private", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "kind", default: "public_channel", null: false
    t.boolean "is_archived", default: false, null: false
    t.boolean "is_shared", default: false, null: false
    t.bigint "created_unix"
    t.decimal "backfill_anchor_latest_ts", precision: 16, scale: 6
    t.decimal "backfill_next_oldest_ts", precision: 16, scale: 6
    t.integer "backfill_window_days", default: 30, null: false
    t.boolean "backfill_complete", default: false, null: false
    t.decimal "forward_newest_ts", precision: 16, scale: 6
    t.datetime "last_audit_at"
    t.string "last_history_status"
    t.text "last_history_error"
    t.bigint "team_id"
    t.boolean "history_unreachable", default: false, null: false
    t.integer "estimated_message_count"
    t.datetime "message_count_estimated_at"
    t.index ["history_unreachable"], name: "index_channels_on_history_unreachable"
    t.index ["integration_id", "external_channel_id"], name: "index_channels_on_integration_id_and_external_channel_id", unique: true
    t.index ["integration_id"], name: "index_channels_on_integration_id"
    t.index ["kind"], name: "index_channels_on_kind"
    t.index ["team_id"], name: "index_channels_on_team_id"
  end

  create_table "charges", force: :cascade do |t|
    t.bigint "subscription_id", null: false
    t.string "stripe_charge_id", null: false
    t.integer "amount", null: false
    t.integer "stripe_fee"
    t.integer "commission"
    t.bigint "affiliate_id", null: false
    t.bigint "customer_id"
    t.bigint "payout_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["affiliate_id"], name: "index_charges_on_affiliate_id"
    t.index ["customer_id"], name: "index_charges_on_customer_id"
    t.index ["payout_id"], name: "index_charges_on_payout_id"
    t.index ["stripe_charge_id"], name: "index_charges_on_stripe_charge_id", unique: true
    t.index ["subscription_id"], name: "index_charges_on_subscription_id"
  end

  create_table "clara_overviews", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.bigint "metric_id", null: false
    t.text "content"
    t.string "status", default: "pending", null: false
    t.datetime "generated_at"
    t.datetime "expires_at"
    t.text "error_message"
    t.string "openai_model"
    t.string "request_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "range_start"
    t.date "range_end"
    t.string "group_scope"
    t.index ["expires_at"], name: "index_clara_overviews_on_expires_at"
    t.index ["metric_id"], name: "index_clara_overviews_on_metric_id"
    t.index ["status"], name: "index_clara_overviews_on_status"
    t.index ["workspace_id", "metric_id", "created_at"], name: "index_clara_overviews_on_ws_metric_created_at"
    t.index ["workspace_id", "metric_id", "range_start", "range_end", "created_at"], name: "index_clara_overviews_on_ws_metric_range_created_at"
    t.index ["workspace_id", "metric_id", "range_start", "range_end", "group_scope", "created_at"], name: "index_clara_overviews_on_ws_metric_range_group_scope"
    t.index ["workspace_id"], name: "index_clara_overviews_on_workspace_id"
  end

  create_table "commission_entries", force: :cascade do |t|
    t.bigint "partner_id", null: false
    t.bigint "customer_id"
    t.bigint "subscription_id"
    t.bigint "payout_id"
    t.bigint "source_event_id"
    t.bigint "actor_user_id"
    t.string "entry_type", null: false
    t.integer "amount_cents", null: false
    t.string "currency", default: "usd", null: false
    t.datetime "occurred_at", null: false
    t.date "effective_on"
    t.string "source_external_id", null: false
    t.string "source_invoice_id"
    t.string "source_charge_id"
    t.string "source_refund_id"
    t.string "source_dispute_id"
    t.text "reason"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_commission_entries_on_actor_user_id"
    t.index ["customer_id"], name: "index_commission_entries_on_customer_id"
    t.index ["effective_on"], name: "index_commission_entries_on_effective_on"
    t.index ["entry_type"], name: "index_commission_entries_on_entry_type"
    t.index ["occurred_at"], name: "index_commission_entries_on_occurred_at"
    t.index ["partner_id", "occurred_at"], name: "index_commission_entries_on_partner_id_and_occurred_at"
    t.index ["partner_id"], name: "index_commission_entries_on_partner_id"
    t.index ["payout_id"], name: "index_commission_entries_on_payout_id"
    t.index ["source_charge_id"], name: "index_commission_entries_on_source_charge_id"
    t.index ["source_dispute_id"], name: "index_commission_entries_on_source_dispute_id"
    t.index ["source_event_id"], name: "index_commission_entries_on_source_event_id"
    t.index ["source_external_id"], name: "index_commission_entries_on_source_external_id", unique: true
    t.index ["source_refund_id"], name: "index_commission_entries_on_source_refund_id"
    t.index ["subscription_id"], name: "index_commission_entries_on_subscription_id"
  end

  create_table "detections", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.bigint "signal_category_id", null: false
    t.bigint "model_test_id", null: false
    t.bigint "async_inference_result_id", null: false
    t.jsonb "full_output", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "score"
    t.float "logit_score"
    t.string "polarity", limit: 8, null: false
    t.integer "metric_id"
    t.integer "submetric_id"
    t.integer "signal_subcategory_id"
    t.float "logit_margin"
    t.index ["logit_margin"], name: "index_detections_on_logit_margin"
    t.index ["message_id", "polarity", "logit_margin", "id"], name: "idx_detections_policy_optimization", order: { logit_margin: :desc }, where: "(logit_margin IS NOT NULL)"
    t.index ["message_id", "signal_category_id", "model_test_id", "polarity"], name: "index_detections_on_msg_sc_mt_polarity", unique: true
    t.index ["message_id"], name: "index_detections_on_message_id"
    t.index ["metric_id", "logit_margin"], name: "index_detections_on_metric_logit_margin_partial", where: "(logit_margin IS NOT NULL)"
    t.index ["signal_category_id", "logit_margin"], name: "index_detections_on_signal_category_logit_margin_partial", where: "(logit_margin IS NOT NULL)"
    t.index ["signal_category_id"], name: "index_detections_on_signal_category_id"
    t.index ["submetric_id", "logit_margin"], name: "index_detections_on_submetric_logit_margin_partial", where: "(logit_margin IS NOT NULL)"
  end

  create_table "examples", force: :cascade do |t|
    t.bigint "template_id", null: false
    t.string "label", null: false
    t.text "message", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "length_type"
    t.string "style_type"
    t.datetime "generated_at"
    t.boolean "verified"
    t.index ["length_type"], name: "index_examples_on_length_type"
    t.index ["style_type"], name: "index_examples_on_style_type"
    t.index ["template_id"], name: "index_examples_on_template_id"
    t.index ["verified"], name: "index_examples_on_verified"
  end

  create_table "group_members", force: :cascade do |t|
    t.bigint "group_id", null: false
    t.bigint "integration_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id", "integration_user_id"], name: "index_group_members_on_group_id_and_integration_user_id", unique: true
    t.index ["group_id"], name: "index_group_members_on_group_id"
    t.index ["integration_user_id"], name: "index_group_members_on_integration_user_id"
  end

  create_table "groups", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id"], name: "index_groups_on_workspace_id"
  end

  create_table "insight_deliveries", force: :cascade do |t|
    t.bigint "insight_id", null: false
    t.bigint "user_id"
    t.string "channel", null: false
    t.string "status", default: "pending", null: false
    t.string "provider_message_id"
    t.jsonb "metadata", default: {}, null: false
    t.text "error_message"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["insight_id", "channel", "user_id"], name: "index_insight_deliveries_on_insight_channel_user"
    t.index ["insight_id"], name: "index_insight_deliveries_on_insight_id"
    t.index ["user_id"], name: "index_insight_deliveries_on_user_id"
  end

  create_table "insight_detection_rollups", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.string "subject_type", null: false
    t.bigint "subject_id", null: false
    t.string "dimension_type", null: false
    t.bigint "dimension_id", null: false
    t.bigint "metric_id"
    t.date "posted_on", null: false
    t.decimal "logit_margin_min", precision: 10, scale: 4, default: "0.0", null: false
    t.integer "total_count", default: 0, null: false
    t.integer "positive_count", default: 0, null: false
    t.integer "negative_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "logit_margin_min"], name: "idx_insight_det_rollups_workspace_margin_threshold"
    t.index ["workspace_id", "posted_on"], name: "idx_insight_det_rollups_workspace_day"
    t.index ["workspace_id", "subject_type", "subject_id", "dimension_type", "dimension_id", "metric_id", "logit_margin_min", "posted_on"], name: "idx_insight_det_rollups_unique_margin", unique: true
  end

  create_table "insight_driver_items", force: :cascade do |t|
    t.bigint "insight_id", null: false
    t.string "driver_type", null: false
    t.bigint "driver_id", null: false
    t.float "weight"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["driver_type", "driver_id"], name: "index_insight_driver_items_on_driver_type_and_driver_id"
    t.index ["insight_id"], name: "index_insight_driver_items_on_insight_id"
  end

  create_table "insight_pipeline_runs", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.datetime "snapshot_at", null: false
    t.string "mode", default: "dry_run", null: false
    t.string "status", default: "ok", null: false
    t.decimal "logit_margin_min", precision: 10, scale: 4, default: "0.0", null: false
    t.integer "candidates_total"
    t.integer "candidates_primary"
    t.integer "accepted_primary"
    t.integer "persisted_count"
    t.integer "delivered"
    t.jsonb "timings", default: {}, null: false
    t.jsonb "error_payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "created_at"], name: "idx_insight_pipeline_runs_workspace_created"
    t.index ["workspace_id", "snapshot_at"], name: "idx_insight_pipeline_runs_workspace_snapshot"
  end

  create_table "insight_trigger_templates", force: :cascade do |t|
    t.string "key", null: false
    t.string "driver_type", null: false
    t.string "name", null: false
    t.text "description"
    t.text "subject_scopes", default: "", null: false
    t.string "dimension_type", null: false
    t.string "direction"
    t.boolean "primary", default: true, null: false
    t.integer "window_days"
    t.integer "baseline_days"
    t.integer "window_offset_days", default: 0, null: false
    t.integer "min_window_detections"
    t.integer "min_baseline_detections"
    t.decimal "min_current_rate", precision: 10, scale: 4
    t.decimal "min_delta_rate", precision: 10, scale: 4
    t.decimal "min_z_score", precision: 10, scale: 4
    t.decimal "severity_weight", precision: 10, scale: 4
    t.integer "cooldown_days"
    t.integer "max_per_subject_per_window"
    t.text "system_prompt"
    t.jsonb "metadata", default: {}, null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_insight_trigger_templates_on_enabled"
    t.index ["key"], name: "index_insight_trigger_templates_on_key", unique: true
  end

  create_table "insights", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.string "subject_type", null: false
    t.bigint "subject_id", null: false
    t.bigint "metric_id"
    t.string "kind", null: false
    t.string "polarity", null: false
    t.float "severity", null: false
    t.datetime "window_start_at", null: false
    t.datetime "window_end_at", null: false
    t.datetime "baseline_start_at"
    t.datetime "baseline_end_at"
    t.string "summary_title"
    t.text "summary_body"
    t.jsonb "data_payload", default: {}, null: false
    t.string "state", default: "pending", null: false
    t.datetime "delivered_at"
    t.datetime "next_eligible_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "trigger_template_id"
    t.jsonb "affected_members", default: [], null: false
    t.datetime "affected_members_captured_at"
    t.index ["affected_members_captured_at"], name: "index_insights_on_affected_members_captured_at"
    t.index ["metric_id"], name: "index_insights_on_metric_id"
    t.index ["state"], name: "index_insights_on_state"
    t.index ["trigger_template_id"], name: "index_insights_on_trigger_template_id"
    t.index ["workspace_id", "metric_id"], name: "index_insights_on_workspace_id_and_metric_id"
    t.index ["workspace_id", "subject_type", "subject_id", "created_at"], name: "index_insights_on_subject_and_created_at", order: { created_at: :desc }
    t.index ["workspace_id", "subject_type", "subject_id"], name: "index_insights_on_workspace_id_and_subject_type_and_subject_id"
    t.index ["workspace_id"], name: "index_insights_on_workspace_id"
  end

  create_table "integration_users", force: :cascade do |t|
    t.bigint "integration_id", null: false
    t.bigint "user_id"
    t.string "slack_user_id", null: false
    t.string "role", default: "member"
    t.string "slack_history_token"
    t.string "slack_bot_token"
    t.string "slack_refresh_token"
    t.datetime "slack_token_expires_at"
    t.string "display_name"
    t.string "real_name"
    t.string "email"
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "invited_at"
    t.datetime "channels_last_synced_at"
    t.datetime "rate_limited_until"
    t.integer "rate_limit_last_retry_after_seconds"
    t.datetime "profile_refreshed_at"
    t.boolean "is_bot", default: false, null: false
    t.boolean "active", default: true, null: false
    t.string "title"
    t.text "ms_access_token"
    t.text "ms_refresh_token"
    t.datetime "ms_expires_at"
    t.index ["active"], name: "index_integration_users_on_active"
    t.index ["integration_id", "slack_user_id"], name: "index_ws_users_on_ws_and_slack_id", unique: true
    t.index ["integration_id", "user_id"], name: "index_ws_users_on_ws_and_user", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["integration_id"], name: "index_integration_users_on_integration_id"
    t.index ["user_id"], name: "index_integration_users_on_user_id"
  end

  create_table "integrations", force: :cascade do |t|
    t.string "slack_team_id"
    t.string "name"
    t.string "domain"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "sync_status", default: "queued", null: false
    t.datetime "last_synced_at"
    t.boolean "analyze_complete", default: false, null: false
    t.integer "days_analyzed", default: 0, null: false
    t.bigint "workspace_id", null: false
    t.string "kind", default: "slack", null: false
    t.string "ms_tenant_id"
    t.string "ms_display_name"
    t.string "setup_status", default: "queued", null: false
    t.string "setup_step"
    t.integer "setup_progress", default: 0, null: false
    t.text "setup_error"
    t.datetime "setup_started_at"
    t.datetime "setup_completed_at"
    t.integer "setup_channels_count", default: 0, null: false
    t.integer "setup_users_count", default: 0, null: false
    t.integer "setup_memberships_count", default: 0, null: false
    t.index ["kind"], name: "index_integrations_on_kind"
    t.index ["ms_tenant_id", "workspace_id"], name: "index_integrations_on_ms_tenant_and_workspace"
    t.index ["setup_status"], name: "index_integrations_on_setup_status"
    t.index ["slack_team_id", "workspace_id"], name: "index_integrations_on_slack_team_and_workspace", unique: true
    t.index ["workspace_id"], name: "index_integrations_on_workspace_id"
  end

  create_table "link_clicks", force: :cascade do |t|
    t.bigint "link_id", null: false
    t.bigint "created_user_id"
    t.string "ip"
    t.string "user_agent"
    t.string "referrer"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "click_uuid"
    t.string "referer_domain"
    t.string "device_type"
    t.string "os"
    t.string "browser"
    t.string "country"
    t.string "region"
    t.string "city"
    t.boolean "is_mobile", default: false, null: false
    t.boolean "is_bot", default: false, null: false
    t.index ["country"], name: "index_link_clicks_on_country"
    t.index ["created_user_id"], name: "index_link_clicks_on_created_user_id"
    t.index ["device_type"], name: "index_link_clicks_on_device_type"
    t.index ["link_id"], name: "index_link_clicks_on_link_id"
    t.index ["referer_domain"], name: "index_link_clicks_on_referer_domain"
  end

  create_table "links", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_links_on_code", unique: true
    t.index ["user_id"], name: "index_links_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "integration_user_id", null: false
    t.bigint "integration_id", null: false
    t.bigint "channel_id", null: false
    t.string "slack_ts", null: false
    t.datetime "posted_at"
    t.text "text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "processed", default: false, null: false
    t.datetime "sent_for_inference_at"
    t.datetime "processed_at"
    t.string "slack_thread_ts"
    t.string "subtype"
    t.datetime "edited_at"
    t.boolean "deleted", default: false, null: false
    t.boolean "references_processed", default: false, null: false
    t.datetime "references_processed_at"
    t.datetime "text_purged_at"
    t.text "text_original"
    t.string "original_language", limit: 10
    t.index ["channel_id", "slack_ts"], name: "index_messages_on_channel_id_and_slack_ts", unique: true
    t.index ["channel_id"], name: "index_messages_on_channel_id"
    t.index ["integration_id", "posted_at", "id"], name: "idx_messages_integration_posted_id"
    t.index ["integration_id", "posted_at"], name: "index_messages_on_integration_id_and_posted_at"
    t.index ["integration_id"], name: "index_messages_on_integration_id"
    t.index ["integration_user_id", "posted_at"], name: "index_messages_on_integration_user_id_and_posted_at"
    t.index ["integration_user_id"], name: "index_messages_on_integration_user_id"
    t.index ["processed"], name: "index_messages_on_processed"
    t.index ["processed_at"], name: "index_messages_on_processed_at"
    t.index ["references_processed"], name: "index_messages_on_references_processed"
    t.index ["sent_for_inference_at"], name: "index_messages_on_sent_for_inference_at"
    t.index ["slack_thread_ts"], name: "index_messages_on_slack_thread_ts"
    t.index ["text_purged_at"], name: "index_messages_on_text_purged_at"
  end

  create_table "metrics", force: :cascade do |t|
    t.bigint "framework_id"
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "reverse", default: false
    t.integer "sort"
    t.string "description"
    t.text "about"
    t.string "link"
    t.string "short_description"
    t.index ["framework_id"], name: "index_metrics_on_framework_id"
  end

  create_table "model_test_detections", force: :cascade do |t|
    t.bigint "model_test_id", null: false
    t.bigint "message_id", null: false
    t.bigint "signal_category_id", null: false
    t.string "description"
    t.decimal "score", precision: 5, scale: 2
    t.text "provided_context"
    t.text "full_output"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "signal_subcategory_id"
    t.string "indicator_type"
    t.integer "ai_quality_score"
    t.integer "human_quality_score"
    t.integer "async_inference_result_id"
    t.decimal "confidence", precision: 8, scale: 6
    t.decimal "logit", precision: 12, scale: 6
    t.index ["confidence"], name: "index_model_test_detections_on_confidence"
    t.index ["logit"], name: "index_model_test_detections_on_logit"
    t.index ["message_id"], name: "index_model_test_detections_on_message_id"
    t.index ["model_test_id"], name: "index_model_test_detections_on_model_test_id"
    t.index ["signal_category_id"], name: "index_model_test_detections_on_signal_category_id"
  end

  create_table "model_tests", force: :cascade do |t|
    t.string "name"
    t.string "test_type", null: false
    t.text "context"
    t.bigint "integration_id"
    t.bigint "model_id"
    t.bigint "signal_category_id"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.integer "estimated_cost"
    t.float "duration"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "prev_message_count", default: 5
    t.integer "prev_detection_count", default: 5
    t.string "scoring_instructions"
    t.string "output_instructions"
    t.boolean "ai_quality_reviewed", default: false
    t.boolean "human_quality_reviewed", default: false
    t.string "description"
    t.string "openai_batch_id"
    t.string "openai_review_batch_id"
    t.boolean "active", default: false, null: false
    t.index ["active"], name: "index_model_tests_on_active_true", unique: true, where: "active"
    t.index ["integration_id"], name: "index_model_tests_on_integration_id"
    t.index ["model_id"], name: "index_model_tests_on_model_id"
    t.index ["signal_category_id"], name: "index_model_tests_on_signal_category_id"
  end

  create_table "models", force: :cascade do |t|
    t.string "name", null: false
    t.string "description"
    t.string "endpoint_name"
    t.string "endpoint_config_name"
    t.string "endpoint_arn"
    t.string "endpoint_status", default: "pending"
    t.string "sagemaker_model_name"
    t.string "instance_type", default: "ml.m5.xlarge"
    t.string "status", default: "pending"
    t.text "model_info"
    t.integer "concurrent_requests", default: 5
    t.integer "max_server_instances", default: 1
    t.string "jumpstart_model_id"
    t.string "container_image_uri"
    t.string "model_data_url"
    t.jsonb "environment_variables", default: {}
    t.string "deployment_type"
    t.string "hf_model_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "aws_instance_id"
    t.string "openai_model"
    t.integer "min_server_instances", default: 0
    t.string "hf_task", default: "feature-extraction"
    t.string "inference_mode", default: "async", null: false
    t.string "hf_dlc_image"
  end

  create_table "notification_preferences", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.bigint "user_id", null: false
    t.boolean "email_enabled"
    t.boolean "slack_enabled"
    t.boolean "teams_enabled"
    t.boolean "personal_insights_enabled"
    t.boolean "all_group_insights_enabled"
    t.boolean "my_group_insights_enabled"
    t.boolean "executive_summaries_enabled"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_notification_preferences_on_user_id"
    t.index ["workspace_id", "user_id"], name: "index_notification_preferences_on_workspace_id_and_user_id", unique: true
    t.index ["workspace_id"], name: "index_notification_preferences_on_workspace_id"
  end

  create_table "partner_provisioning_events", force: :cascade do |t|
    t.string "contact_id", null: false
    t.string "email"
    t.bigint "user_id"
    t.string "status", default: "received", null: false
    t.jsonb "payload", default: {}, null: false
    t.text "error"
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contact_id"], name: "index_partner_provisioning_events_on_contact_id", unique: true
    t.index ["status"], name: "index_partner_provisioning_events_on_status"
    t.index ["user_id"], name: "index_partner_provisioning_events_on_user_id"
  end

  create_table "partner_resources", force: :cascade do |t|
    t.string "category", null: false
    t.string "title", null: false
    t.string "url", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "resource_type", default: "file", null: false
    t.string "hex"
    t.index ["category"], name: "index_partner_resources_on_category"
    t.index ["resource_type"], name: "index_partner_resources_on_resource_type"
  end

  create_table "payout_audit_logs", force: :cascade do |t|
    t.bigint "actor_user_id"
    t.bigint "payout_batch_id"
    t.bigint "payout_batch_item_id"
    t.bigint "partner_id"
    t.string "action", null: false
    t.jsonb "details", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_payout_audit_logs_on_action"
    t.index ["actor_user_id"], name: "index_payout_audit_logs_on_actor_user_id"
    t.index ["created_at"], name: "index_payout_audit_logs_on_created_at"
    t.index ["partner_id"], name: "index_payout_audit_logs_on_partner_id"
    t.index ["payout_batch_id"], name: "index_payout_audit_logs_on_payout_batch_id"
    t.index ["payout_batch_item_id"], name: "index_payout_audit_logs_on_payout_batch_item_id"
  end

  create_table "payout_batch_items", force: :cascade do |t|
    t.bigint "payout_batch_id", null: false
    t.bigint "partner_id", null: false
    t.bigint "payout_id"
    t.bigint "payout_method_id"
    t.string "status", default: "draft", null: false
    t.integer "base_amount_cents", default: 0, null: false
    t.integer "adjustment_amount_cents", default: 0, null: false
    t.integer "final_amount_cents", default: 0, null: false
    t.boolean "included", default: true, null: false
    t.boolean "batch_paused", default: false, null: false
    t.boolean "approved", default: false, null: false
    t.boolean "payable", default: false, null: false
    t.string "blocked_reason"
    t.string "trolley_payment_id"
    t.string "submit_idempotency_key"
    t.datetime "submitted_at"
    t.datetime "paid_at"
    t.datetime "failed_at"
    t.text "override_reason"
    t.datetime "override_expires_at"
    t.jsonb "gate_snapshot", default: {}, null: false
    t.jsonb "readiness_snapshot", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["partner_id"], name: "index_payout_batch_items_on_partner_id"
    t.index ["payout_batch_id", "partner_id"], name: "index_payout_batch_items_on_payout_batch_id_and_partner_id", unique: true
    t.index ["payout_batch_id"], name: "index_payout_batch_items_on_payout_batch_id"
    t.index ["payout_id"], name: "index_payout_batch_items_on_payout_id"
    t.index ["payout_method_id"], name: "index_payout_batch_items_on_payout_method_id"
    t.index ["status"], name: "index_payout_batch_items_on_status"
    t.index ["submit_idempotency_key"], name: "index_payout_batch_items_on_submit_idempotency_key", unique: true
    t.index ["trolley_payment_id"], name: "index_payout_batch_items_on_trolley_payment_id", unique: true
  end

  create_table "payout_batches", force: :cascade do |t|
    t.date "period_start", null: false
    t.date "period_end", null: false
    t.string "status", default: "draft", null: false
    t.bigint "built_by_id"
    t.bigint "submitted_by_id"
    t.datetime "built_at"
    t.datetime "submitted_at"
    t.datetime "paid_at"
    t.datetime "failed_at"
    t.integer "eligible_count", default: 0, null: false
    t.integer "blocked_count", default: 0, null: false
    t.integer "submitted_count", default: 0, null: false
    t.integer "paid_count", default: 0, null: false
    t.integer "gross_amount_cents", default: 0, null: false
    t.integer "submitted_amount_cents", default: 0, null: false
    t.integer "paid_amount_cents", default: 0, null: false
    t.integer "rebuild_count", default: 0, null: false
    t.string "submit_idempotency_key"
    t.text "notes"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["built_by_id"], name: "index_payout_batches_on_built_by_id"
    t.index ["period_start", "period_end"], name: "index_payout_batches_on_period_start_and_period_end"
    t.index ["status"], name: "index_payout_batches_on_status"
    t.index ["submit_idempotency_key"], name: "index_payout_batches_on_submit_idempotency_key", unique: true
    t.index ["submitted_by_id"], name: "index_payout_batches_on_submitted_by_id"
  end

  create_table "payout_methods", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "method", null: false
    t.jsonb "details", default: {}
    t.boolean "is_default", default: false, null: false
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "is_default"], name: "index_payout_methods_on_user_id_and_is_default", where: "(is_default = true)"
    t.index ["user_id", "method"], name: "index_payout_methods_on_user_id_and_method", unique: true
    t.index ["user_id"], name: "index_payout_methods_on_user_id"
  end

  create_table "payout_settings", force: :cascade do |t|
    t.string "key", null: false
    t.string "value", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_payout_settings_on_key", unique: true
  end

  create_table "payouts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "payout_method_id"
    t.integer "amount", null: false
    t.date "start_date", null: false
    t.date "end_date", null: false
    t.datetime "paid_at"
    t.string "external_id"
    t.string "status", default: "pending"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["payout_method_id"], name: "index_payouts_on_payout_method_id"
    t.index ["user_id", "start_date", "end_date"], name: "index_payouts_on_user_id_and_start_date_and_end_date", unique: true
    t.index ["user_id"], name: "index_payouts_on_user_id"
  end

  create_table "prompt_test_runs", force: :cascade do |t|
    t.string "prompt_key", null: false
    t.string "prompt_type"
    t.bigint "prompt_version_id"
    t.bigint "created_by_id"
    t.string "title"
    t.text "body"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_prompt_test_runs_on_created_by_id"
    t.index ["prompt_key", "prompt_version_id", "created_at"], name: "index_prompt_test_runs_on_key_version_created"
    t.index ["prompt_version_id"], name: "index_prompt_test_runs_on_prompt_version_id"
  end

  create_table "prompt_versions", force: :cascade do |t|
    t.string "key", null: false
    t.integer "version", default: 1, null: false
    t.string "label"
    t.text "content", null: false
    t.boolean "active", default: false, null: false
    t.bigint "created_by_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_prompt_versions_on_created_by_id"
    t.index ["key", "version"], name: "index_prompt_versions_on_key_and_version", unique: true
    t.index ["key"], name: "idx_prompt_versions_unique_active", unique: true, where: "active"
    t.index ["key"], name: "index_prompt_versions_on_key"
  end

  create_table "reference_mentions", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.bigint "reference_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "reference_id"], name: "uniq_reference_mentions_msgid_ref", unique: true
    t.index ["message_id"], name: "index_reference_mentions_on_message_id"
    t.index ["reference_id"], name: "index_reference_mentions_on_reference_id"
  end

  create_table "references", force: :cascade do |t|
    t.string "kind", null: false
    t.string "value", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind", "value"], name: "uniq_references_kind_value", unique: true
    t.index ["value"], name: "idx_references_value_trgm", opclass: :gin_trgm_ops, using: :gin
  end

  create_table "signal_categories", force: :cascade do |t|
    t.bigint "submetric_id", null: false
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.float "positive_threshold"
    t.float "negative_threshold"
    t.index ["submetric_id"], name: "index_signal_categories_on_submetric_id"
  end

  create_table "signal_subcategories", force: :cascade do |t|
    t.bigint "signal_category_id", null: false
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "description"
    t.index ["signal_category_id"], name: "index_signal_subcategories_on_signal_category_id"
  end

  create_table "stripe_webhook_events", force: :cascade do |t|
    t.string "stripe_event_id", null: false
    t.string "event_type", null: false
    t.boolean "livemode", default: false, null: false
    t.jsonb "payload", default: {}, null: false
    t.string "processing_state", default: "pending", null: false
    t.integer "attempts_count", default: 0, null: false
    t.text "last_error"
    t.datetime "processed_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_type", "created_at"], name: "index_stripe_webhook_events_on_event_type_and_created_at"
    t.index ["processing_state"], name: "index_stripe_webhook_events_on_processing_state"
    t.index ["stripe_event_id"], name: "index_stripe_webhook_events_on_stripe_event_id", unique: true
  end

  create_table "submetrics", force: :cascade do |t|
    t.bigint "metric_id", null: false
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.string "short_description"
    t.index ["metric_id"], name: "index_submetrics_on_metric_id"
    t.index ["short_description"], name: "index_submetrics_on_short_description"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "stripe_subscription_id", null: false
    t.string "status"
    t.date "started_on"
    t.date "expires_on"
    t.integer "amount", null: false
    t.string "interval"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_id"
    t.index ["stripe_subscription_id"], name: "index_subscriptions_on_stripe_subscription_id", unique: true
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
    t.index ["workspace_id"], name: "index_subscriptions_on_workspace_id"
  end

  create_table "team_memberships", force: :cascade do |t|
    t.bigint "team_id", null: false
    t.bigint "integration_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_user_id"], name: "index_team_memberships_on_integration_user_id"
    t.index ["team_id", "integration_user_id"], name: "index_team_memberships_on_team_id_and_integration_user_id", unique: true
    t.index ["team_id"], name: "index_team_memberships_on_team_id"
  end

  create_table "teams", force: :cascade do |t|
    t.bigint "integration_id", null: false
    t.string "ms_team_id", null: false
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_id", "ms_team_id"], name: "index_teams_on_integration_id_and_ms_team_id", unique: true
    t.index ["integration_id"], name: "index_teams_on_integration_id"
  end

  create_table "templates", force: :cascade do |t|
    t.string "metric", null: false
    t.string "sub_metric", null: false
    t.string "signal_category", null: false
    t.string "signal", null: false
    t.text "positive_indicator"
    t.text "negative_indicator"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "positive_description"
    t.text "negative_description"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "slack_sso_token"
    t.string "first_name"
    t.string "last_name"
    t.boolean "admin", default: false
    t.boolean "partner"
    t.bigint "referred_by_link_id"
    t.string "auth_provider"
    t.boolean "payout_manager", default: false, null: false
    t.boolean "payout_approved", default: false, null: false
    t.datetime "payout_approved_at"
    t.bigint "payout_approved_by_id"
    t.boolean "payout_paused", default: false, null: false
    t.datetime "payout_paused_at"
    t.text "payout_pause_reason"
    t.bigint "payout_paused_by_id"
    t.datetime "payout_gate_override_until"
    t.text "payout_gate_override_reason"
    t.bigint "payout_gate_override_by_id"
    t.string "trolley_refid"
    t.string "trolley_recipient_id"
    t.string "trolley_recipient_status"
    t.boolean "trolley_ready", default: false, null: false
    t.datetime "trolley_last_checked_at"
    t.jsonb "trolley_readiness_payload", default: {}, null: false
    t.integer "payout_single_approved_cents", default: 0, null: false
    t.integer "payout_lifetime_approved_cents", default: 0, null: false
    t.integer "payout_max_refund_allowed_cents"
    t.index ["auth_provider"], name: "index_users_on_auth_provider"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["payout_approved"], name: "index_users_on_payout_approved"
    t.index ["payout_approved_by_id"], name: "index_users_on_payout_approved_by_id"
    t.index ["payout_gate_override_by_id"], name: "index_users_on_payout_gate_override_by_id"
    t.index ["payout_manager"], name: "index_users_on_payout_manager"
    t.index ["payout_paused"], name: "index_users_on_payout_paused"
    t.index ["payout_paused_by_id"], name: "index_users_on_payout_paused_by_id"
    t.index ["referred_by_link_id"], name: "index_users_on_referred_by_link_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["trolley_recipient_id"], name: "index_users_on_trolley_recipient_id", unique: true
    t.index ["trolley_refid"], name: "index_users_on_trolley_refid", unique: true
  end

  create_table "workspace_insight_template_overrides", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.bigint "trigger_template_id", null: false
    t.boolean "enabled", default: true, null: false
    t.jsonb "overrides", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "trigger_template_id"], name: "idx_workspace_template_overrides_unique", unique: true
  end

  create_table "workspace_invites", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.bigint "integration_user_id", null: false
    t.bigint "invited_by_id", null: false
    t.string "email", null: false
    t.string "name"
    t.string "role", default: "user", null: false
    t.string "status", default: "pending", null: false
    t.datetime "accepted_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "token_digest"
    t.index ["integration_user_id"], name: "index_workspace_invites_on_integration_user_id"
    t.index ["invited_by_id"], name: "index_workspace_invites_on_invited_by_id"
    t.index ["token_digest"], name: "index_workspace_invites_on_token_digest", unique: true
    t.index ["workspace_id", "integration_user_id"], name: "index_workspace_invites_on_workspace_and_integration_user", unique: true
    t.index ["workspace_id"], name: "index_workspace_invites_on_workspace_id"
  end

  create_table "workspace_notification_permissions", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.string "account_type", null: false
    t.boolean "enabled", default: true, null: false
    t.text "allowed_types", default: [], array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "account_type"], name: "index_notification_permissions_on_workspace_and_account_type", unique: true
    t.index ["workspace_id"], name: "index_workspace_notification_permissions_on_workspace_id"
  end

  create_table "workspace_users", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.bigint "user_id", null: false
    t.boolean "is_owner", default: false, null: false
    t.string "role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_workspace_users_on_user_id"
    t.index ["workspace_id", "user_id"], name: "index_workspace_users_on_workspace_id_and_user_id", unique: true
    t.index ["workspace_id"], name: "index_workspace_users_on_workspace_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.bigint "owner_id", null: false
    t.string "name", null: false
    t.string "stripe_customer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "archived_at"
    t.datetime "dashboard_ready_notified_at"
    t.datetime "welcome_notified_at"
    t.index ["archived_at"], name: "index_workspaces_on_archived_at"
    t.index ["dashboard_ready_notified_at"], name: "index_workspaces_on_dashboard_ready_notified_at"
    t.index ["name"], name: "uniq_workspaces_demo_workspace_name", unique: true, where: "((name)::text = 'Demo Workspace'::text)"
    t.index ["owner_id"], name: "index_workspaces_on_owner_id"
    t.index ["welcome_notified_at"], name: "index_workspaces_on_welcome_notified_at"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_chat_conversations", "users"
  add_foreign_key "ai_chat_conversations", "workspaces"
  add_foreign_key "ai_chat_messages", "ai_chat_conversations"
  add_foreign_key "async_inference_results", "model_tests"
  add_foreign_key "benchmark_labels", "benchmark_messages"
  add_foreign_key "benchmark_review_recommendations", "benchmark_messages"
  add_foreign_key "benchmark_review_recommendations", "users"
  add_foreign_key "benchmark_review_scenario_states", "users"
  add_foreign_key "channel_identities", "channels"
  add_foreign_key "channel_identities", "integration_users"
  add_foreign_key "channel_identities", "integrations"
  add_foreign_key "channel_memberships", "channels"
  add_foreign_key "channel_memberships", "integration_users"
  add_foreign_key "channel_memberships", "integrations"
  add_foreign_key "channels", "integrations"
  add_foreign_key "channels", "teams"
  add_foreign_key "charges", "payouts"
  add_foreign_key "charges", "subscriptions"
  add_foreign_key "charges", "users", column: "affiliate_id"
  add_foreign_key "charges", "users", column: "customer_id"
  add_foreign_key "clara_overviews", "metrics"
  add_foreign_key "clara_overviews", "workspaces"
  add_foreign_key "commission_entries", "payouts"
  add_foreign_key "commission_entries", "stripe_webhook_events", column: "source_event_id"
  add_foreign_key "commission_entries", "subscriptions"
  add_foreign_key "commission_entries", "users", column: "actor_user_id"
  add_foreign_key "commission_entries", "users", column: "customer_id"
  add_foreign_key "commission_entries", "users", column: "partner_id"
  add_foreign_key "detections", "async_inference_results"
  add_foreign_key "detections", "messages"
  add_foreign_key "detections", "model_tests"
  add_foreign_key "detections", "signal_categories"
  add_foreign_key "examples", "templates"
  add_foreign_key "group_members", "groups"
  add_foreign_key "group_members", "integration_users"
  add_foreign_key "groups", "workspaces"
  add_foreign_key "insight_deliveries", "insights"
  add_foreign_key "insight_deliveries", "users"
  add_foreign_key "insight_driver_items", "insights"
  add_foreign_key "insight_pipeline_runs", "workspaces"
  add_foreign_key "insights", "insight_trigger_templates", column: "trigger_template_id"
  add_foreign_key "insights", "metrics"
  add_foreign_key "insights", "workspaces"
  add_foreign_key "integration_users", "integrations"
  add_foreign_key "integration_users", "users"
  add_foreign_key "integrations", "workspaces"
  add_foreign_key "link_clicks", "links"
  add_foreign_key "link_clicks", "users", column: "created_user_id"
  add_foreign_key "links", "users"
  add_foreign_key "messages", "channels"
  add_foreign_key "messages", "integration_users"
  add_foreign_key "messages", "integrations"
  add_foreign_key "model_test_detections", "messages"
  add_foreign_key "model_test_detections", "model_tests"
  add_foreign_key "model_test_detections", "signal_categories"
  add_foreign_key "model_tests", "integrations"
  add_foreign_key "notification_preferences", "users"
  add_foreign_key "notification_preferences", "workspaces"
  add_foreign_key "payout_audit_logs", "payout_batch_items"
  add_foreign_key "payout_audit_logs", "payout_batches"
  add_foreign_key "payout_audit_logs", "users", column: "actor_user_id"
  add_foreign_key "payout_audit_logs", "users", column: "partner_id"
  add_foreign_key "payout_batch_items", "payout_batches"
  add_foreign_key "payout_batch_items", "payout_methods"
  add_foreign_key "payout_batch_items", "payouts"
  add_foreign_key "payout_batch_items", "users", column: "partner_id"
  add_foreign_key "payout_batches", "users", column: "built_by_id"
  add_foreign_key "payout_batches", "users", column: "submitted_by_id"
  add_foreign_key "payout_methods", "users"
  add_foreign_key "payouts", "payout_methods"
  add_foreign_key "payouts", "users"
  add_foreign_key "prompt_test_runs", "prompt_versions"
  add_foreign_key "prompt_test_runs", "users", column: "created_by_id"
  add_foreign_key "prompt_versions", "users", column: "created_by_id"
  add_foreign_key "reference_mentions", "messages", on_delete: :cascade
  add_foreign_key "reference_mentions", "references", on_delete: :cascade
  add_foreign_key "signal_categories", "submetrics"
  add_foreign_key "signal_subcategories", "signal_categories"
  add_foreign_key "submetrics", "metrics"
  add_foreign_key "subscriptions", "users"
  add_foreign_key "subscriptions", "workspaces"
  add_foreign_key "team_memberships", "integration_users"
  add_foreign_key "team_memberships", "teams"
  add_foreign_key "teams", "integrations"
  add_foreign_key "users", "links", column: "referred_by_link_id"
  add_foreign_key "users", "users", column: "payout_approved_by_id"
  add_foreign_key "users", "users", column: "payout_gate_override_by_id"
  add_foreign_key "users", "users", column: "payout_paused_by_id"
  add_foreign_key "workspace_insight_template_overrides", "insight_trigger_templates", column: "trigger_template_id"
  add_foreign_key "workspace_insight_template_overrides", "workspaces"
  add_foreign_key "workspace_invites", "integration_users"
  add_foreign_key "workspace_invites", "users", column: "invited_by_id"
  add_foreign_key "workspace_invites", "workspaces"
  add_foreign_key "workspace_notification_permissions", "workspaces"
  add_foreign_key "workspace_users", "users"
  add_foreign_key "workspace_users", "workspaces"
  add_foreign_key "workspaces", "users", column: "owner_id"
end
