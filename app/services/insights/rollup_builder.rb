module Insights
  # Builds daily detection rollups (by subject + dimension) so we can simulate insight thresholds
  # without touching the live Insights engine.
  class RollupBuilder
    POSTED_AT_SQL = Insights::QueryHelpers::POSTED_AT_SQL

    def initialize(workspace:, logit_margin_min:, start_date: nil, end_date: Date.current, logger: Rails.logger)
      @workspace = workspace
      @logit_margin_min = logit_margin_min.to_f
      @start_date = start_date
      @end_date = end_date || Date.current
      @logger = logger
    end

    def run!
      raise ArgumentError, "workspace required" unless workspace
      raise ArgumentError, "end_date required" unless end_date

      build_workspace_rollups!
      build_user_rollups!
      build_group_rollups!
    end

    private

    attr_reader :workspace, :logit_margin_min, :start_date, :end_date, :logger

    def build_workspace_rollups!
      %w[metric submetric category].each do |dimension_type|
        insert_rollups!(
          subject_type: "Workspace",
          subject_id_sql: workspace.id.to_s,
          dimension_type: dimension_type,
          dimension_column: dimension_column_for(dimension_type),
          metric_id_sql: metric_id_sql_for(dimension_type),
          group_by_subject: false  # subject_id is a constant, don't GROUP BY it
        )
      end
    end

    def build_user_rollups!
      %w[metric submetric category].each do |dimension_type|
        insert_rollups!(
          subject_type: "IntegrationUser",
          subject_id_sql: "integration_users.id",
          dimension_type: dimension_type,
          dimension_column: dimension_column_for(dimension_type),
          metric_id_sql: metric_id_sql_for(dimension_type),
          joins: "INNER JOIN integration_users ON integration_users.id = messages.integration_user_id INNER JOIN group_members ON group_members.integration_user_id = integration_users.id INNER JOIN groups ON groups.id = group_members.group_id",
          additional_where: "groups.workspace_id = #{workspace.id}"
        )
      end
    end

    def build_group_rollups!
      %w[metric submetric category].each do |dimension_type|
        insert_rollups!(
          subject_type: "Group",
          subject_id_sql: "group_members.group_id",
          dimension_type: dimension_type,
          dimension_column: dimension_column_for(dimension_type),
          metric_id_sql: metric_id_sql_for(dimension_type),
          joins: "INNER JOIN integration_users ON integration_users.id = messages.integration_user_id INNER JOIN group_members ON group_members.integration_user_id = integration_users.id INNER JOIN groups ON groups.id = group_members.group_id",
          additional_where: "group_members.group_id IS NOT NULL AND groups.workspace_id = #{workspace.id}"
        )
      end
    end

    def insert_rollups!(subject_type:, subject_id_sql:, dimension_type:, dimension_column:, metric_id_sql:, joins: "", additional_where: nil, group_by_subject: true)
      dimension_condition = "#{dimension_column} IS NOT NULL"
      where_fragments = [
        "integrations.workspace_id = #{workspace.id}",
        DetectionPolicy.sql_condition(table_alias: "detections"),
        dimension_condition
      ]
      where_fragments << additional_where if additional_where.present?
      where_fragments << date_where_clause if date_where_clause.present?

      # Build GROUP BY clause - only include subject_id_sql if it's a column reference (not a literal)
      # For Workspace rollups, subject_id is a constant so we don't GROUP BY it
      group_by_parts = []
      group_by_parts << subject_id_sql if group_by_subject
      group_by_parts << dimension_column
      group_by_parts << metric_id_sql
      group_by_parts << posted_date_sql

      sql = <<~SQL
        INSERT INTO insight_detection_rollups
          (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, posted_on, logit_margin_min, total_count, positive_count, negative_count, created_at, updated_at)
        SELECT
          #{workspace.id} AS workspace_id,
          #{connection.quote(subject_type)} AS subject_type,
          #{subject_id_sql} AS subject_id,
          #{connection.quote(dimension_type)} AS dimension_type,
          #{dimension_column} AS dimension_id,
          #{metric_id_sql} AS metric_id,
          #{posted_date_sql} AS posted_on,
          #{logit_margin_min.to_f} AS logit_margin_min,
          COUNT(*) AS total_count,
          COUNT(*) FILTER (WHERE detections.polarity = 'positive') AS positive_count,
          COUNT(*) FILTER (WHERE detections.polarity = 'negative') AS negative_count,
          NOW() AS created_at,
          NOW() AS updated_at
        FROM detections
        INNER JOIN messages ON messages.id = detections.message_id
        INNER JOIN integrations ON integrations.id = messages.integration_id
        #{joins}
        WHERE #{where_fragments.join(" AND ")}
        GROUP BY #{group_by_parts.join(", ")}
        ON CONFLICT (workspace_id, subject_type, subject_id, dimension_type, dimension_id, metric_id, logit_margin_min, posted_on)
        DO UPDATE SET
          metric_id = EXCLUDED.metric_id,
          total_count = EXCLUDED.total_count,
          positive_count = EXCLUDED.positive_count,
          negative_count = EXCLUDED.negative_count,
          updated_at = NOW();
      SQL

      connection.execute(sql)
    end

    def dimension_column_for(dimension_type)
      case dimension_type
      when "metric" then "detections.metric_id"
      when "submetric" then "detections.submetric_id"
      when "category" then "detections.signal_category_id"
      else
        raise ArgumentError, "unknown dimension_type #{dimension_type}"
      end
    end

    def metric_id_sql_for(dimension_type)
      case dimension_type
      when "metric"
        "detections.metric_id"
      when "submetric"
        "detections.metric_id"
      when "category"
        "detections.metric_id"
      else
        "NULL"
      end
    end

    def date_where_clause
      clauses = []
      clauses << "#{posted_date_sql} >= #{connection.quote(start_date)}" if start_date
      clauses << "#{posted_date_sql} <= #{connection.quote(end_date)}" if end_date
      clauses.join(" AND ")
    end

    def posted_date_sql
      "DATE(#{POSTED_AT_SQL})"
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
