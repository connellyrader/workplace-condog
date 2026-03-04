# frozen_string_literal: true

namespace :rollups do
  desc "Backfill insight_detection_rollups from existing detections"
  task backfill: :environment do
    puts "Starting rollup backfill..."

    logit_margin_min = ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f
    workspaces = Workspace.joins(:integrations).distinct

    puts "Found #{workspaces.count} workspaces with integrations"

    workspaces.find_each do |workspace|
      puts "Processing workspace #{workspace.id}: #{workspace.name}"

      # Find date range for this workspace
      date_range = Detection
        .joins(message: :integration)
        .where(integrations: { workspace_id: workspace.id })
        .where("detections.logit_margin >= ?", logit_margin_min)
        .pluck(Arel.sql("MIN(DATE(messages.posted_at))"), Arel.sql("MAX(DATE(messages.posted_at))"))
        .first

      next unless date_range&.first && date_range&.last

      start_date = date_range.first
      end_date = date_range.last

      puts "  Date range: #{start_date} to #{end_date}"

      builder = Insights::RollupBuilder.new(
        workspace: workspace,
        logit_margin_min: logit_margin_min,
        start_date: start_date,
        end_date: end_date,
        logger: Rails.logger
      )

      builder.run!
      puts "  Done"
    end

    puts "Backfill complete!"
  end

  desc "Rebuild rollups for a specific workspace"
  task :rebuild, [:workspace_id] => :environment do |_t, args|
    workspace_id = args[:workspace_id]
    abort "Usage: rake rollups:rebuild[workspace_id]" if workspace_id.blank?

    workspace = Workspace.find(workspace_id)
    logit_margin_min = ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f

    puts "Rebuilding rollups for workspace #{workspace.id}: #{workspace.name}"

    # Delete existing rollups for this workspace
    deleted = InsightDetectionRollup.where(workspace_id: workspace.id).delete_all
    puts "  Deleted #{deleted} existing rollup rows"

    # Find date range
    date_range = Detection
      .joins(message: :integration)
      .where(integrations: { workspace_id: workspace.id })
      .where("detections.logit_margin >= ?", logit_margin_min)
      .pluck(Arel.sql("MIN(DATE(messages.posted_at))"), Arel.sql("MAX(DATE(messages.posted_at))"))
      .first

    unless date_range&.first && date_range&.last
      puts "  No detections found"
      exit
    end

    start_date = date_range.first
    end_date = date_range.last

    puts "  Date range: #{start_date} to #{end_date}"

    builder = Insights::RollupBuilder.new(
      workspace: workspace,
      logit_margin_min: logit_margin_min,
      start_date: start_date,
      end_date: end_date,
      logger: Rails.logger
    )

    builder.run!

    count = InsightDetectionRollup.where(workspace_id: workspace.id).count
    puts "  Created #{count} rollup rows"
    puts "Done!"
  end

  desc "Show rollup stats"
  task stats: :environment do
    total = InsightDetectionRollup.count
    by_workspace = InsightDetectionRollup.group(:workspace_id).count
    by_subject_type = InsightDetectionRollup.group(:subject_type).count
    by_dimension_type = InsightDetectionRollup.group(:dimension_type).count

    puts "Total rollup rows: #{total}"

    puts "\nBy subject type:"
    by_subject_type.each do |subject_type, count|
      puts "  #{subject_type}: #{count}"
    end

    puts "\nBy dimension type:"
    by_dimension_type.each do |dim_type, count|
      puts "  #{dim_type}: #{count}"
    end

    puts "\nBy workspace:"
    by_workspace.each do |ws_id, count|
      ws = Workspace.find_by(id: ws_id)
      puts "  #{ws_id} (#{ws&.name || 'unknown'}): #{count}"
    end

    if total > 0
      date_range = InsightDetectionRollup.pluck(Arel.sql("MIN(posted_on)"), Arel.sql("MAX(posted_on)")).first
      puts "\nDate range: #{date_range.first} to #{date_range.last}"

      # Group rollup stats
      group_count = InsightDetectionRollup.where(subject_type: "Group").select(:subject_id).distinct.count
      puts "\nUnique groups with rollups: #{group_count}"
    end
  end

  desc "Backfill group rollups only (faster if workspace rollups already exist)"
  task backfill_groups: :environment do
    puts "Starting group rollup backfill..."

    logit_margin_min = ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0").to_f
    workspaces = Workspace.joins(:integrations).distinct

    puts "Found #{workspaces.count} workspaces with integrations"

    workspaces.find_each do |workspace|
      puts "Processing workspace #{workspace.id}: #{workspace.name}"

      # Find date range for this workspace
      date_range = Detection
        .joins(message: :integration)
        .where(integrations: { workspace_id: workspace.id })
        .where("detections.logit_margin >= ?", logit_margin_min)
        .pluck(Arel.sql("MIN(DATE(messages.posted_at))"), Arel.sql("MAX(DATE(messages.posted_at))"))
        .first

      next unless date_range&.first && date_range&.last

      start_date = date_range.first
      end_date = date_range.last

      puts "  Date range: #{start_date} to #{end_date}"

      # Delete existing group rollups for this workspace
      deleted = InsightDetectionRollup
        .where(workspace_id: workspace.id, subject_type: "Group")
        .delete_all
      puts "  Deleted #{deleted} existing group rollup rows"

      # Build group rollups using the same logic as RollupBuilder
      %w[metric submetric category].each do |dimension_type|
        dimension_column = case dimension_type
                           when "metric" then "detections.metric_id"
                           when "submetric" then "detections.submetric_id"
                           when "category" then "detections.signal_category_id"
                           end

        sql = <<~SQL
          INSERT INTO insight_detection_rollups
            (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, posted_on, logit_margin_min, total_count, positive_count, negative_count, created_at, updated_at)
          SELECT
            #{workspace.id} AS workspace_id,
            'Group' AS subject_type,
            group_members.group_id AS subject_id,
            '#{dimension_type}' AS dimension_type,
            #{dimension_column} AS dimension_id,
            detections.metric_id AS metric_id,
            DATE(COALESCE(messages.posted_at, messages.created_at)) AS posted_on,
            #{logit_margin_min} AS logit_margin_min,
            COUNT(*) AS total_count,
            COUNT(*) FILTER (WHERE detections.polarity = 'positive') AS positive_count,
            COUNT(*) FILTER (WHERE detections.polarity = 'negative') AS negative_count,
            NOW() AS created_at,
            NOW() AS updated_at
          FROM detections
          INNER JOIN messages ON messages.id = detections.message_id
          INNER JOIN integrations ON integrations.id = messages.integration_id
          INNER JOIN integration_users ON integration_users.id = messages.integration_user_id
          INNER JOIN group_members ON group_members.integration_user_id = integration_users.id
          INNER JOIN groups ON groups.id = group_members.group_id
          WHERE integrations.workspace_id = #{workspace.id}
            AND detections.logit_margin >= #{logit_margin_min}
            AND #{dimension_column} IS NOT NULL
            AND groups.workspace_id = #{workspace.id}
            AND DATE(COALESCE(messages.posted_at, messages.created_at)) >= '#{start_date}'
            AND DATE(COALESCE(messages.posted_at, messages.created_at)) <= '#{end_date}'
          GROUP BY group_members.group_id, #{dimension_column}, detections.metric_id, DATE(COALESCE(messages.posted_at, messages.created_at))
          ON CONFLICT (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, logit_margin_min, posted_on)
          DO UPDATE SET
            metric_id = EXCLUDED.metric_id,
            total_count = EXCLUDED.total_count,
            positive_count = EXCLUDED.positive_count,
            negative_count = EXCLUDED.negative_count,
            updated_at = NOW();
        SQL

        ActiveRecord::Base.connection.execute(sql)
      end

      count = InsightDetectionRollup.where(workspace_id: workspace.id, subject_type: "Group").count
      puts "  Created #{count} group rollup rows"
    end

    puts "Group rollup backfill complete!"
  end
end

