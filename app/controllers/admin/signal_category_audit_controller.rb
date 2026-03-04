# frozen_string_literal: true

class Admin::SignalCategoryAuditController < ApplicationController
  layout "admin"
  before_action :authenticate_admin

  WORKSPACE_ID = 78

  def index
    @workspace = Workspace.find_by(id: WORKSPACE_ID)
    @range_end = Time.zone.today
    @range_start = @range_end - 29.days

    counts = Detection
      .joins(:signal_category, message: :integration)
      .where(integrations: { workspace_id: WORKSPACE_ID })
      .where("messages.posted_at >= ? AND messages.posted_at <= ?", @range_start.beginning_of_day, @range_end.end_of_day)
      .merge(Detection.with_scoring_policy)
      .group("signal_categories.id")
      .pluck(
        "signal_categories.id",
        Arel.sql("SUM(CASE WHEN detections.polarity = 'positive' THEN 1 ELSE 0 END)"),
        Arel.sql("COUNT(*)")
      )

    counts_by_sc = counts.each_with_object({}) do |(sc_id, pos, tot), h|
      h[sc_id.to_i] = { pos: pos.to_i, tot: tot.to_i }
    end

    @rows = SignalCategory
      .joins(submetric: :metric)
      .select("signal_categories.id, signal_categories.name, submetrics.name AS submetric_name, metrics.name AS metric_name, metrics.reverse AS metric_reverse")
      .order("metrics.name ASC, submetrics.name ASC, signal_categories.name ASC")
      .map do |row|
        c = counts_by_sc[row.id] || { pos: 0, tot: 0 }
        score = if c[:tot] > 0
          pct = (c[:pos].to_f / c[:tot].to_f) * 100.0
          pct = 100.0 - pct if row.metric_reverse
          pct.round
        end

        {
          signal_category_id: row.id,
          metric_name: row.metric_name,
          submetric_name: row.submetric_name,
          signal_category_name: row.name,
          score: score,
          detections: c[:tot]
        }
      end
  end

  def details
    signal_category_id = params[:signal_category_id].to_i
    range_end = Time.zone.today
    range_start = range_end - 29.days

    message_rows = Detection
      .joins(message: :integration)
      .where(integrations: { workspace_id: WORKSPACE_ID })
      .where("messages.posted_at >= ? AND messages.posted_at <= ?", range_start.beginning_of_day, range_end.end_of_day)
      .where(signal_category_id: signal_category_id)
      .merge(Detection.with_scoring_policy)
      .group("messages.id", "messages.posted_at", "messages.subtype")
      .order("messages.posted_at DESC", "messages.id DESC")
      .pluck("messages.id", "messages.posted_at", "messages.subtype")

    message_ids = message_rows.map { |r| r[0] }

    labels_by_message = if message_ids.any?
      Detection
        .joins(:signal_category, message: :integration)
        .where(integrations: { workspace_id: WORKSPACE_ID })
        .where(message_id: message_ids)
        .merge(Detection.with_scoring_policy)
        .group("detections.message_id")
        .pluck(
          "detections.message_id",
          Arel.sql("STRING_AGG(DISTINCT signal_categories.name || ' [' || detections.polarity || ']', ', ' ORDER BY signal_categories.name || ' [' || detections.polarity || ']')")
        ).to_h
    else
      {}
    end

    rows = message_rows.map do |message_id, posted_at, subtype|
      {
        message_id: message_id,
        posted_at: posted_at,
        subtype: subtype,
        passed_labels: labels_by_message[message_id].to_s
      }
    end

    render json: { rows: rows }
  end
end
