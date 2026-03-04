class Admin::BenchmarkReviewsController < ApplicationController
  layout "admin"
  before_action :authenticate_admin

  GROUPS_PER_PAGE = 10

  def index
    @benchmark_set = params[:benchmark_set].presence || BenchmarkMessage.order(created_at: :desc).limit(1).pick(:benchmark_set) || "golden_rules_v2_polarity204"
    @all_labels = BenchmarkLabel.joins(:benchmark_message).where(benchmark_messages: { benchmark_set: @benchmark_set }).distinct.order(:label_name).pluck(:label_name)

    scenario_rows = BenchmarkMessage
      .where(benchmark_set: @benchmark_set)
      .group(:label_primary, :scenario_id)
      .pluck(:label_primary, :scenario_id, Arel.sql("COUNT(*)"))

    states = BenchmarkReviewScenarioState
      .where(user_id: current_user.id, benchmark_set: @benchmark_set)
      .index_by { |s| [s.label_primary, s.scenario_id] }

    scenarios = scenario_rows.map do |label_primary, scenario_id, msg_count|
      state = states[[label_primary, scenario_id]]
      {
        label_primary: label_primary,
        scenario_id: scenario_id,
        message_count: msg_count.to_i,
        done: !!state&.done,
        comment: state&.comment.to_s
      }
    end

    # Unreviewed first; reviewed scenarios pushed to end of pagination
    scenarios.sort_by! { |s| [s[:done] ? 1 : 0, s[:label_primary].to_s, s[:scenario_id].to_s] }

    @total_groups = scenarios.size
    @total_pages = [(@total_groups.to_f / GROUPS_PER_PAGE).ceil, 1].max
    @page = params[:page].to_i
    @page = 1 if @page < 1
    @page = @total_pages if @page > @total_pages

    @scenarios_page = scenarios.slice((@page - 1) * GROUPS_PER_PAGE, GROUPS_PER_PAGE) || []

    where_clauses = @scenarios_page.map { "(label_primary = ? AND scenario_id = ?)" }
    binds = @scenarios_page.flat_map { |s| [s[:label_primary], s[:scenario_id]] }

    @messages = if where_clauses.any?
      BenchmarkMessage
        .includes(:benchmark_labels)
        .where(benchmark_set: @benchmark_set)
        .where(where_clauses.join(" OR "), *binds)
        .order(:label_primary, :scenario_id, :external_message_id)
    else
      BenchmarkMessage.none
    end

    @grouped_messages = @messages.group_by { |m| [m.label_primary, m.scenario_id] }

    @my_recommendations = BenchmarkReviewRecommendation
      .where(user_id: current_user.id, benchmark_message_id: @messages.map(&:id))
      .index_by { |r| [r.benchmark_message_id, r.label_name] }

    @scenario_state_map = @scenarios_page.index_by { |s| [s[:label_primary], s[:scenario_id]] }

    page_label_primaries = @scenarios_page.map { |s| s[:label_primary] }.uniq
    @signal_definition_by_label = build_signal_definition_map(page_label_primaries)
  end

  def upsert
    benchmark_message = BenchmarkMessage.find(params[:benchmark_message_id])

    label_name = params[:label_name].to_s.strip
    recommendation = params[:recommendation].to_s.strip

    if label_name.blank? || recommendation.blank?
      return render json: { ok: false, error: "Label and recommendation are required." }, status: :unprocessable_entity
    end

    rec = BenchmarkReviewRecommendation.find_or_initialize_by(
      benchmark_message_id: benchmark_message.id,
      user_id: current_user.id,
      label_name: label_name
    )

    rec.recommendation = recommendation

    if rec.save
      render json: { ok: true }
    else
      render json: { ok: false, error: rec.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  def destroy
    benchmark_message = BenchmarkMessage.find(params[:benchmark_message_id])
    label_name = params[:label_name].to_s.strip

    rec = BenchmarkReviewRecommendation.find_by(
      benchmark_message_id: benchmark_message.id,
      user_id: current_user.id,
      label_name: label_name
    )

    rec&.destroy
    render json: { ok: true }
  end

  def mark_scenario_done
    state = upsert_scenario_state(done: true)
    return unless state

    render json: { ok: true }
  end

  def mark_scenario_open
    state = upsert_scenario_state(done: false)
    return unless state

    render json: { ok: true }
  end

  private

  def upsert_scenario_state(done:)
    benchmark_set = params[:benchmark_set].to_s.strip
    label_primary = params[:label_primary].to_s.strip
    scenario_id = params[:scenario_id].to_s.strip
    comment = params[:comment].to_s.strip

    if benchmark_set.blank? || label_primary.blank? || scenario_id.blank?
      render json: { ok: false, error: "benchmark_set, label_primary, and scenario_id are required." }, status: :unprocessable_entity
      return nil
    end

    state = BenchmarkReviewScenarioState.find_or_initialize_by(
      user_id: current_user.id,
      benchmark_set: benchmark_set,
      label_primary: label_primary,
      scenario_id: scenario_id
    )

    state.done = done
    state.done_at = done ? Time.current : nil
    state.comment = comment

    unless state.save
      render json: { ok: false, error: state.errors.full_messages.to_sentence }, status: :unprocessable_entity
      return nil
    end

    state
  end

  def base_slug_from_label(label)
    label.to_s.sub(/__(positive|negative|none)\z/, "")
  end

  def slugify_signal_category_name(name)
    name.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/_+/, "_").gsub(/^_|_$/, "")
  end

  def build_signal_definition_map(label_primaries)
    wanted = label_primaries.map { |lp| [lp, base_slug_from_label(lp)] }.to_h
    definitions_by_slug = SignalCategory.pluck(:name, :description).each_with_object({}) do |(name, description), h|
      h[slugify_signal_category_name(name)] = description.to_s
    end

    wanted.each_with_object({}) do |(label_primary, slug), h|
      h[label_primary] = definitions_by_slug[slug].presence || "Definition unavailable."
    end
  end
end
