# lib/tasks/insights_baseline_stats.rake
require "csv"

namespace :insights do
  desc "Compute baseline stats distributions to tune InsightTriggerTemplate thresholds"
  task baseline_stats: :environment do
    workspace_id        = ENV["WORKSPACE_ID"]
    as_of_str           = ENV["AS_OF"] || "2025-08-27" # e.g. "2025-12-11" or "2025-12-11 12:00"
    lookback_days       = (ENV["LOOKBACK_DAYS"] || "90").to_i
    sample_users        = (ENV["SAMPLE_USERS"] || "50").to_i
    sample_groups       = (ENV["SAMPLE_GROUPS"] || "50").to_i
    max_dims_per_subject= (ENV["MAX_DIMS_PER_SUBJECT"] || "50").to_i
    snapshots           = (ENV["SNAPSHOTS"] || "4").to_i           # number of as_of snapshots
    snapshot_step_days  = (ENV["SNAPSHOT_STEP_DAYS"] || "7").to_i  # spacing between snapshots
    output              = ENV["OUTPUT"] || "tmp/insights_baseline_stats.csv"
    pending_only        = ENV["PENDING_ONLY"].to_s == "1"
    template_keys       = ENV["TEMPLATE_KEYS"]&.split(",")&.map(&:strip) # optional filter

    as_of = as_of_str.present? ? Time.zone.parse(as_of_str) : Time.current
    as_ofs = snapshots.times.map { |i| as_of - (i * snapshot_step_days).days }

    workspaces =
      if workspace_id.present?
        [Workspace.find(workspace_id)]
      else
        Workspace.all
      end

    puts "[insights:baseline_stats] workspaces=#{workspaces.size} as_ofs=#{as_ofs.map { |t| t.to_date }.join(", ")}"
    puts "[insights:baseline_stats] lookback_days=#{lookback_days} sample_users=#{sample_users} sample_groups=#{sample_groups} max_dims_per_subject=#{max_dims_per_subject}"
    puts "[insights:baseline_stats] output=#{output} pending_only=#{pending_only} template_keys=#{template_keys&.join(",") || "(all)"}"

    report = Insights::TemplateTuningReport.new(
      workspaces: workspaces,
      as_ofs: as_ofs,
      lookback_days: lookback_days,
      sample_users: sample_users,
      sample_groups: sample_groups,
      max_dims_per_subject: max_dims_per_subject,
      pending_only: pending_only,
      template_keys: template_keys,
      output_path: output,
      logger: Rails.logger
    )

    result = report.run!

    puts "\n[insights:baseline_stats] Summary"
    Array(result[:summary]).each do |row|
      puts " - #{row[:template_key]} (scope=#{row[:scope]}) n=#{row[:n]} " \
          "win_total_p50=#{row[:window_total_p50]} " \
          "rate_p90=#{row[:rate_p90]} delta_p90=#{row[:delta_p90]}"
    end

    puts "\n[insights:baseline_stats] Grid Recommendations"
    Array(result[:grid_recommendations]).each do |rec|
      best = rec[:best] || {}
      puts " - #{rec[:template_key]} (scope=#{rec[:scope]}) target=#{rec[:target_rate]} " \
          "best_fire_rate=#{best[:fire_rate]} fired=#{best[:fired]}/#{best[:total]} " \
          "thresholds=#{best[:thresholds].inspect}"
    end


    puts "\n[insights:baseline_stats] Wrote #{output}"
  end
end
