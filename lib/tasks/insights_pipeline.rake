namespace :insights do
  desc "Build daily rollups for yesterday (all workspaces unless WORKSPACE_IDS provided)"
  task rollups_daily: :environment do
    logit_margin_min = ( ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")).to_f
    baseline_mode = ENV.fetch("INSIGHTS_BASELINE_MODE", "trailing")
    range_days = (ENV["INSIGHTS_RANGE_DAYS"] || "1").to_i
    range_days = 1 if range_days <= 0
    snapshot_at = parse_snapshot_time(ENV["SNAPSHOT_AT"]) || Time.zone.yesterday.end_of_day

    workspaces = workspaces_from_env
    puts "[insights:rollups_daily] workspaces=#{workspaces.count} snapshot_at=#{snapshot_at} range_days=#{range_days} logit=#{logit_margin_min} baseline=#{baseline_mode}"

    workspaces.find_each do |workspace|
      result = Insights::Pipeline::Rollups.ensure_rollups!(
        workspace: workspace,
        snapshot_at: snapshot_at,
        baseline_mode: baseline_mode,
        logit_margin_min: logit_margin_min,
        range_days: range_days,
        logger: Rails.logger
      )
      status = result.built ? "built" : "cached"
      puts "[insights:rollups_daily] workspace=#{workspace.id} #{status} #{result.start_date}→#{result.end_date}"
    rescue => e
      Rails.logger.error("[insights:rollups_daily] workspace=#{workspace.id} error #{e.class}: #{e.message}")
      puts "[insights:rollups_daily] workspace=#{workspace.id} error #{e.class}: #{e.message}"
    end
  end

  desc "Run daily insights for yesterday (persist accepted, notify by default)"
  task run_daily: :environment do
    logit_margin_min = ( ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")).to_f
    baseline_mode = ENV.fetch("INSIGHTS_BASELINE_MODE", "trailing")
    range_days = (ENV["INSIGHTS_RANGE_DAYS"] || "1").to_i
    range_days = 1 if range_days <= 0
    snapshot_at = parse_snapshot_time(ENV["SNAPSHOT_AT"]) || Time.zone.yesterday.end_of_day
    notify = ENV.fetch("INSIGHTS_NOTIFY", "true").to_s != "false"

    workspaces = workspaces_from_env
    puts "[insights:run_daily] workspaces=#{workspaces.count} snapshot_at=#{snapshot_at} range_days=#{range_days} logit=#{logit_margin_min} baseline=#{baseline_mode} notify=#{notify}"

    workspaces.find_each do |workspace|
      result = Insights::Pipeline::Runner.new(
        workspace: workspace,
        snapshot_at: snapshot_at,
        baseline_mode: baseline_mode,
        logit_margin_min: logit_margin_min,
        range_days: range_days,
        mode: "persist",
        notify: notify,
        logger: Rails.logger
      ).run!

      puts "[insights:run_daily] workspace=#{workspace.id} run=#{result.run.id} candidates=#{result.run.candidates_primary} accepted=#{result.run.accepted_primary} persisted=#{result.run.persisted_count}"
      if result.persist_result&.errors.present?
        puts "[insights:run_daily] workspace=#{workspace.id} persist_errors=#{result.persist_result.errors.size}"
        result.persist_result.errors.first(5).each do |entry|
          err = entry[:error]
          msg = err ? "#{err.class}: #{err.message}" : "unknown_error"
          puts "[insights:run_daily] persist_error #{msg}"
        end
      end
    rescue => e
      Rails.logger.error("[insights:run_daily] workspace=#{workspace.id} error #{e.class}: #{e.message}")
      puts "[insights:run_daily] workspace=#{workspace.id} error #{e.class}: #{e.message}"
    end
  end

  desc "Build full rollups for a workspace (optionally bounded). Usage: rake insights:rollups_full[WORKSPACE_ID,START_DATE,END_DATE]"
  task :rollups_full, [:workspace_id, :start_date, :end_date] => :environment do |_task, args|
    workspace_id = args[:workspace_id].presence || ENV["WORKSPACE_ID"]
    raise ArgumentError, "WORKSPACE_ID is required" if workspace_id.blank?

    workspace = Workspace.find_by(id: workspace_id)
    raise ArgumentError, "Workspace not found: #{workspace_id}" unless workspace

    start_date = parse_date_arg(args[:start_date] || ENV["START_DATE"])
    end_date = parse_date_arg(args[:end_date] || ENV["END_DATE"]) || Time.zone.yesterday.to_date
    logit_margin_min = ( ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")).to_f

    range_label =
      if start_date
        "#{start_date}→#{end_date}"
      else
        "full_history→#{end_date}"
      end

    puts "[insights:rollups_full] workspace=#{workspace.id} range=#{range_label} logit=#{logit_margin_min}"

    Insights::RollupBuilder.new(
      workspace: workspace,
      logit_margin_min: logit_margin_min,
      start_date: start_date,
      end_date: end_date,
      logger: Rails.logger
    ).run!

    puts "[insights:rollups_full] workspace=#{workspace.id} done"
  rescue => e
    Rails.logger.error("[insights:rollups_full] workspace=#{workspace_id} error #{e.class}: #{e.message}")
    puts "[insights:rollups_full] workspace=#{workspace_id} error #{e.class}: #{e.message}"
  end

  desc "Manual range run for a workspace (persist, no notifications). Runs daily across the range. Usage: rake insights:run_range[WORKSPACE_ID,START_DATE,END_DATE]"
  task :run_range, [:workspace_id, :start_date, :end_date] => :environment do |_task, args|
    workspace_id = args[:workspace_id].presence || ENV["WORKSPACE_ID"]
    start_date = parse_date_arg(args[:start_date] || ENV["START_DATE"])
    end_date = parse_date_arg(args[:end_date] || ENV["END_DATE"])
    raise ArgumentError, "WORKSPACE_ID is required" if workspace_id.blank?
    raise ArgumentError, "START_DATE is required (YYYY-MM-DD)" unless start_date
    raise ArgumentError, "END_DATE is required (YYYY-MM-DD)" unless end_date
    raise ArgumentError, "END_DATE must be >= START_DATE" if end_date < start_date

    workspace = Workspace.find_by(id: workspace_id)
    raise ArgumentError, "Workspace not found: #{workspace_id}" unless workspace

    logit_margin_min = ( ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0")).to_f
    baseline_mode = ENV.fetch("INSIGHTS_BASELINE_MODE", "trailing")
    range_days = (end_date - start_date).to_i + 1
    snapshot_at = end_date.end_of_day

    puts "[insights:run_range] workspace=#{workspace.id} range=#{start_date}→#{end_date} snapshot_at=#{snapshot_at} logit=#{logit_margin_min} baseline=#{baseline_mode} mode=daily"

    rollup_result = Insights::Pipeline::Rollups.ensure_rollups!(
      workspace: workspace,
      snapshot_at: snapshot_at,
      baseline_mode: baseline_mode,
      logit_margin_min: logit_margin_min,
      range_days: range_days,
      logger: Rails.logger
    )
    puts "[insights:run_range] rollups #{rollup_result.built ? "built" : "cached"} #{rollup_result.start_date}→#{rollup_result.end_date}"

    totals = { runs: 0, candidates: 0, accepted: 0, persisted: 0, errors: 0 }

    (start_date..end_date).each do |day|
      day_snapshot = day.end_of_day
      result = Insights::Pipeline::Runner.new(
        workspace: workspace,
        snapshot_at: day_snapshot,
        baseline_mode: baseline_mode,
        logit_margin_min: logit_margin_min,
        range_days: 1,
        mode: "persist",
        notify: false,
        logger: Rails.logger
      ).run!

      totals[:runs] += 1
      totals[:candidates] += result.run.candidates_primary.to_i
      totals[:accepted] += result.run.accepted_primary.to_i
      totals[:persisted] += result.run.persisted_count.to_i
      totals[:errors] += result.persist_result&.errors.to_a.size

      puts "[insights:run_range] day=#{day} run=#{result.run.id} candidates=#{result.run.candidates_primary} accepted=#{result.run.accepted_primary} persisted=#{result.run.persisted_count}"
      if result.persist_result&.errors.present?
        puts "[insights:run_range] day=#{day} persist_errors=#{result.persist_result.errors.size}"
        result.persist_result.errors.first(5).each do |entry|
          err = entry[:error]
          msg = err ? "#{err.class}: #{err.message}" : "unknown_error"
          puts "[insights:run_range] day=#{day} persist_error #{msg}"
        end
      end
    end

    puts "[insights:run_range] totals runs=#{totals[:runs]} candidates=#{totals[:candidates]} accepted=#{totals[:accepted]} persisted=#{totals[:persisted]} errors=#{totals[:errors]}"
  end

  def workspaces_from_env
    ids = ENV["WORKSPACE_IDS"]&.split(",")&.map(&:strip)&.reject(&:blank?)
    ids.present? ? Workspace.where(id: ids) : Workspace.all
  end

  def parse_snapshot_time(raw)
    return nil if raw.blank?
    Time.zone.parse(raw.to_s)
  rescue
    nil
  end

  def parse_date_arg(raw)
    return nil if raw.blank?
    Date.parse(raw.to_s)
  rescue
    nil
  end
end

