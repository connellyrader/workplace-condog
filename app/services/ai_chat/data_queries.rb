# app/services/ai_chat/data_queries.rb
# frozen_string_literal: true

module AiChat
  class DataQueries
    # Minimum rollup rows to consider rollups "available"
    ROLLUP_MIN_ROWS = 10

    # PRIVACY: Minimum population size to return data
    # This protects individual anonymity - never expose data that could identify a single person
    PRIVACY_FLOOR = 3

    # -------- helpers --------

    def self.q(value)
      ActiveRecord::Base.connection.quote(value)
    end

    # Privacy guard: checks that the effective population is >= PRIVACY_FLOOR
    # Returns nil if valid, or an error hash if population is too small
    def self.check_privacy_floor(integration_user_ids)
      return nil if integration_user_ids.blank? # No user filter = workspace-wide = OK
      return nil if integration_user_ids.size >= PRIVACY_FLOOR

      {
        ok: false,
        reason: "population_too_small",
        population_size: integration_user_ids.size,
        min_required: PRIVACY_FLOOR,
        message: "Cannot return data for fewer than #{PRIVACY_FLOOR} users to protect anonymity."
      }
    end

    # Check if rollups are populated for a workspace
    def self.rollups_available?(workspace_id:, logit_margin_min:)
      return false if workspace_id.blank?
      InsightDetectionRollup
        .where(workspace_id: workspace_id, logit_margin_min: logit_margin_min)
        .limit(ROLLUP_MIN_ROWS)
        .count >= ROLLUP_MIN_ROWS
    end

    # integer IN (...) builder
    def self.in_clause_int(column, values)
      vals = Array(values).map { |v| Integer(v) rescue nil }.compact
      # Ignore non-positive ids; our primary keys start at 1, and 0 is used
      # as a “no id” sentinel in some tool payloads.
      vals = vals.select { |v| v.to_i > 0 }
      return nil if vals.empty?
      "#{column} IN (#{vals.join(',')})"
    end

    # LOWER(string) IN ('a','b',...)
    def self.in_clause_str_lower(column, values)
      vals = Array(values).map { |v| ActiveRecord::Base.connection.quote(v.to_s.downcase) }
      return nil if vals.empty?
      "LOWER(#{column}) IN (#{vals.join(',')})"
    end

    # Return integration ids the user can see, optionally scoped to a workspace.
    def self.integration_ids_for_user(user:, workspace_id: nil)
      ids = IntegrationUser.where(user_id: user.id).pluck(:integration_id)
      ids |= Integration.joins(:workspace).where(workspaces: { owner_id: user.id, archived_at: nil }).pluck(:id)

      # Always exclude archived workspaces from AI data visibility
      ids = Integration.joins(:workspace)
                       .where(id: ids)
                       .where(workspaces: { archived_at: nil })
                       .pluck(:id)
                       .uniq

      if workspace_id.present?
        workspace_integration_ids = Integration.joins(:workspace)
                                               .where(workspace_id: workspace_id)
                                               .where(workspaces: { archived_at: nil })
                                               .pluck(:id)
        ids = ids & workspace_integration_ids if ids.any?

        # Owners can still see everything in their ACTIVE workspace even without IntegrationUser rows
        if ids.empty? && Workspace.where(id: workspace_id, owner_id: user.id, archived_at: nil).exists?
          ids = workspace_integration_ids
        end
      end

      ids
    end



    # Legacy method removed - was using AVG(score) instead of dashboard-aligned pos/tot calculation.
    # All scoring now uses dashboard_aligned_score in tool_router.rb for consistency.




    # -------- aggregates (GROUP BY dimension) --------
    # group_by: :category | :metric | :submetric | :subcategory
    # returns [{label, total, pos, neg, pos_rate, neg_rate, avg_logit}]
    def self.window_aggregates(user:, from:, to:, group_by: :category,
                               categories: nil, category_ids: nil,
                               metric_ids: nil, metric_names: nil,
                               submetric_ids: nil, submetric_names: nil,
                               subcategory_ids: nil, subcategory_names: nil,
                               workspace_id: nil, integration_user_ids: nil, workspace_user_ids: nil,
                               min_logit_margin: (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f)

      # Fast path: use rollups if available and no user-specific filtering
      user_filtering = integration_user_ids.present? || workspace_user_ids.present?
      name_filtering = categories.present? || metric_names.present? || submetric_names.present? || subcategory_names.present?
      id_filtering = category_ids.present? || submetric_ids.present? || subcategory_ids.present?
      supported_group = [:metric, :submetric, :category].include?(group_by.to_sym)

      if workspace_id.present? && !user_filtering && !name_filtering && !id_filtering && supported_group
        if rollups_available?(workspace_id: workspace_id, logit_margin_min: min_logit_margin)
          return aggregates_from_rollups(
            workspace_id: workspace_id,
            from: from,
            to: to,
            group_by: group_by,
            metric_ids: metric_ids,
            logit_margin_min: min_logit_margin
          )
        end
      end

      # Slow path: query detections directly
      integration_ids = integration_ids_for_user(user: user, workspace_id: workspace_id)
      return [] if integration_ids.empty?

      dim = case group_by.to_sym
            when :metric      then { label: "mt_name", id: "metric_id",     not_null: "metric_id IS NOT NULL" }
            when :submetric   then { label: "sm_name", id: "sm_id",         not_null: "sm_id IS NOT NULL" }
            when :subcategory then { label: "ssc_name", id: "ssc_id",       not_null: "ssc_id IS NOT NULL" }
            else                   { label: "sc_name", id: "sc_id",         not_null: "sc_id IS NOT NULL" }
            end

      # Scope integration users to the integrations the user can see.
      integration_user_ids ||= workspace_user_ids
      if integration_user_ids.present?
        integration_user_ids = IntegrationUser.where(id: integration_user_ids, integration_id: integration_ids).pluck(:id)
        return [] if integration_user_ids.empty?

        # PRIVACY: Enforce minimum population size
        privacy_error = check_privacy_floor(integration_user_ids)
        return [] if privacy_error
      end

      filters = []
      filters << in_clause_int("j.integration_id", integration_ids)
      filters << "j.posted_at BETWEEN #{q(from)} AND #{q(to)}"
      filters << in_clause_int("j.integration_user_id", integration_user_ids) if integration_user_ids.present?
      filters << DetectionPolicy.sql_condition(table_alias: "j", id_col: "id", message_id_col: "message_id", polarity_col: "polarity", margin_col: "logit_margin")

      # Facet filters (names and/or ids)
      filters << in_clause_str_lower("j.sc_name",   categories)       if categories.present?
      filters << in_clause_int("j.sc_id",           category_ids)     if category_ids.present?
      filters << in_clause_int("j.metric_id",       metric_ids)       if metric_ids.present?
      filters << in_clause_str_lower("j.mt_name",   metric_names)     if metric_names.present?
      filters << in_clause_int("j.sm_id",           submetric_ids)    if submetric_ids.present?
      filters << in_clause_str_lower("j.sm_name",   submetric_names)  if submetric_names.present?
      filters << in_clause_int("j.ssc_id",          subcategory_ids)  if subcategory_ids.present?
      filters << in_clause_str_lower("j.ssc_name",  subcategory_names)if subcategory_names.present?

      filters << dim[:not_null]
      where_sql = filters.compact.join(" AND ")

      sql = <<~SQL
        WITH j AS (
          SELECT
            d.id,
            d.message_id,
            d.polarity,
            d.logit_score,
            d.logit_margin,
            m.integration_id,
            m.integration_user_id,
            m.posted_at,
            sc.id   AS sc_id,
            sc.name AS sc_name,
            sm.id   AS sm_id,
            sm.name AS sm_name,
            COALESCE(d.metric_id, sm.metric_id) AS metric_id,
            mt.name    AS mt_name,
            mt.reverse AS mt_reverse,
            ssc.id     AS ssc_id,
            ssc.name   AS ssc_name
          FROM detections d
          JOIN messages m             ON m.id = d.message_id
          JOIN signal_categories sc   ON sc.id = d.signal_category_id
          LEFT JOIN submetrics sm     ON sm.id = sc.submetric_id
          LEFT JOIN metrics mt        ON mt.id = COALESCE(d.metric_id, sm.metric_id)
          LEFT JOIN signal_subcategories ssc ON ssc.id = d.signal_subcategory_id
        )
        SELECT
          j.#{dim[:label]} AS label,
          COUNT(*)::int AS total,

          -- "Positive" with reverse=false = original positive
          -- "Positive" with reverse=true  = original negative
          COUNT(*) FILTER (
            WHERE
              (COALESCE(j.mt_reverse, FALSE) = FALSE AND j.polarity = 'positive') OR
              (COALESCE(j.mt_reverse, FALSE) = TRUE  AND j.polarity = 'negative')
          )::int AS pos,

          -- "Negative" with reverse=false = original negative
          -- "Negative" with reverse=true  = original positive
          COUNT(*) FILTER (
            WHERE
              (COALESCE(j.mt_reverse, FALSE) = FALSE AND j.polarity = 'negative') OR
              (COALESCE(j.mt_reverse, FALSE) = TRUE  AND j.polarity = 'positive')
          )::int AS neg,

          AVG(j.logit_score)::float AS avg_logit
        FROM j
        WHERE #{where_sql}
        GROUP BY j.#{dim[:label]}
        ORDER BY total DESC
      SQL


      rows = ActiveRecord::Base.connection.exec_query(sql, "ai_window_aggregates")
      rows.map do |r|
        tot = r["total"].to_i
        pos = r["pos"].to_i
        neg = r["neg"].to_i
        {
          label: r["label"],
          total: tot,
          pos:   pos,
          neg:   neg,
          pos_rate: (tot.zero? ? 0.0 : (pos.to_f / tot)).round(6),
          neg_rate: (tot.zero? ? 0.0 : (neg.to_f / tot)).round(6),
          avg_logit: r["avg_logit"]&.to_f
        }
      end
    end

    # -------- timeseries (facet-aware) --------
    # metric: :pos_rate | :neg_rate | :avg_logit | :total
    # Default gate is permissive so charts render even when days are sparse.
    def self.timeseries(user:, category: nil, from:, to:, metric: :pos_rate,
                        workspace_id: nil, integration_user_ids: nil, workspace_user_ids: nil,
                        metric_ids: nil, metric_names: nil,
                        submetric_ids: nil, submetric_names: nil,
                        subcategory_ids: nil, subcategory_names: nil,
                        min_logit_margin: (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f)

      # Fast path: use rollups if available and simple query
      user_filtering = integration_user_ids.present? || workspace_user_ids.present?
      name_filtering = category.present? || metric_names.present? || submetric_names.present? || subcategory_names.present?
      id_filtering = submetric_ids.present? || subcategory_ids.present?
      needs_avg_logit = metric.to_sym == :avg_logit

      if workspace_id.present? && !user_filtering && !name_filtering && !id_filtering && !needs_avg_logit
        if rollups_available?(workspace_id: workspace_id, logit_margin_min: min_logit_margin)
          return timeseries_from_rollups(
            workspace_id: workspace_id,
            from: from,
            to: to,
            metric: metric,
            metric_ids: metric_ids,
            logit_margin_min: min_logit_margin
          )
        end
      end

      # Slow path: query detections directly
      integration_ids = integration_ids_for_user(user: user, workspace_id: workspace_id)
      return [] if integration_ids.empty?

      integration_user_ids ||= workspace_user_ids
      if integration_user_ids.present?
        integration_user_ids = IntegrationUser.where(id: integration_user_ids, integration_id: integration_ids).pluck(:id)
        return [] if integration_user_ids.empty?

        # PRIVACY: Enforce minimum population size
        privacy_error = check_privacy_floor(integration_user_ids)
        return [] if privacy_error
      end

      filters = []
      filters << in_clause_int("j.integration_id", integration_ids)
      filters << "j.posted_at BETWEEN #{q(from)} AND #{q(to)}"
      filters << in_clause_int("j.integration_user_id", integration_user_ids) if integration_user_ids.present?
      filters << DetectionPolicy.sql_condition(table_alias: "j", id_col: "id", message_id_col: "message_id", polarity_col: "polarity", margin_col: "logit_margin")

      if category.present?
        filters << "LOWER(j.sc_name) = #{q(category.to_s.downcase)}"
      else
        filters << in_clause_int("j.metric_id",       metric_ids)       if metric_ids.present?
        filters << in_clause_str_lower("j.mt_name",   metric_names)     if metric_names.present?
        filters << in_clause_int("j.sm_id",           submetric_ids)    if submetric_ids.present?
        filters << in_clause_str_lower("j.sm_name",   submetric_names)  if submetric_names.present?
        filters << in_clause_int("j.ssc_id",          subcategory_ids)  if subcategory_ids.present?
        filters << in_clause_str_lower("j.ssc_name",  subcategory_names)if subcategory_names.present?
      end
      where_sql = filters.compact.join(" AND ")

      from_date_sql = "#{q(from.to_date)}::date"
      to_date_sql   = "#{q(to.to_date)}::date"

      sql = <<~SQL
        WITH j AS (
          SELECT
            d.id,
            d.message_id,
            d.polarity,
            d.logit_score,
            d.logit_margin,
            m.integration_id,
            m.integration_user_id,
            m.posted_at,
            sc.name AS sc_name,
            sm.id   AS sm_id,
            sm.name AS sm_name,
            COALESCE(d.metric_id, sm.metric_id) AS metric_id,
            mt.name    AS mt_name,
            mt.reverse AS mt_reverse,
            ssc.id     AS ssc_id,
            ssc.name   AS ssc_name
          FROM detections d
          JOIN messages m             ON m.id = d.message_id
          JOIN signal_categories sc   ON sc.id = d.signal_category_id
          LEFT JOIN submetrics sm     ON sm.id = sc.submetric_id
          LEFT JOIN metrics mt        ON mt.id = COALESCE(d.metric_id, sm.metric_id)
          LEFT JOIN signal_subcategories ssc ON ssc.id = d.signal_subcategory_id
        ),
        days AS (
          SELECT generate_series(#{from_date_sql}, #{to_date_sql}, '1 day')::date AS day
        ),
        agg AS (
          SELECT
            date_trunc('day', j.posted_at)::date AS day,
            COUNT(*)::int AS total,
            COUNT(*) FILTER (
              WHERE
                (COALESCE(j.mt_reverse, FALSE) = FALSE AND j.polarity = 'positive') OR
                (COALESCE(j.mt_reverse, FALSE) = TRUE  AND j.polarity = 'negative')
            )::int AS pos,
            COUNT(*) FILTER (
              WHERE
                (COALESCE(j.mt_reverse, FALSE) = FALSE AND j.polarity = 'negative') OR
                (COALESCE(j.mt_reverse, FALSE) = TRUE  AND j.polarity = 'positive')
            )::int AS neg,
            AVG(j.logit_score)::float AS avg_logit
          FROM j
          WHERE #{where_sql}
          GROUP BY 1
        )
        SELECT d.day, a.total, a.pos, a.neg, a.avg_logit
        FROM days d
        LEFT JOIN agg a ON a.day = d.day
        ORDER BY d.day
      SQL


      rows = ActiveRecord::Base.connection.exec_query(sql, "ai_timeseries")
      rows.map do |r|
        total = r["total"].to_i
        pos   = r["pos"].to_i
        neg   = r["neg"].to_i
        value =
          case metric.to_sym
          when :total     then total
          when :pos_rate  then (total.zero? ? nil : pos.to_f / total)
          when :neg_rate  then (total.zero? ? nil : neg.to_f / total)
          when :avg_logit then r["avg_logit"]&.to_f
          else total
          end
        { date: r["day"].to_date, value: value }
      end
    end

    # ================================================================
    # ROLLUP-BASED METHODS (fast path)
    # Use these when rollups are available and no user-specific filtering is needed
    # ================================================================

    # Fast timeseries using rollups (workspace-level only, no user filtering)
    def self.timeseries_from_rollups(workspace_id:, from:, to:, metric: :pos_rate,
                                     metric_ids: nil, logit_margin_min: (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f)
      scope = InsightDetectionRollup
        .where(workspace_id: workspace_id, logit_margin_min: logit_margin_min)
        .where(subject_type: "Workspace", subject_id: workspace_id)
        .where(dimension_type: "metric")
        .where(posted_on: from.to_date..to.to_date)

      scope = scope.where(dimension_id: metric_ids) if metric_ids.present?

      rows = scope
        .group(:posted_on)
        .order(:posted_on)
        .pluck(
          :posted_on,
          Arel.sql("SUM(total_count)"),
          Arel.sql("SUM(positive_count)"),
          Arel.sql("SUM(negative_count)")
        )

      # Fill in missing days
      all_days = (from.to_date..to.to_date).to_a
      data_by_day = rows.each_with_object({}) do |(day, tot, pos, neg), h|
        h[day.to_date] = { total: tot.to_i, pos: pos.to_i, neg: neg.to_i }
      end

      all_days.map do |day|
        data = data_by_day[day] || { total: 0, pos: 0, neg: 0 }
        total = data[:total]
        pos = data[:pos]
        neg = data[:neg]

        value = case metric.to_sym
                when :total    then total
                when :pos_rate then (total.zero? ? nil : pos.to_f / total)
                when :neg_rate then (total.zero? ? nil : neg.to_f / total)
                else total
                end

        { date: day, value: value }
      end
    end

    # Fast aggregates using rollups (workspace-level only)
    def self.aggregates_from_rollups(workspace_id:, from:, to:, group_by: :metric,
                                     metric_ids: nil, logit_margin_min: (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f)
      dimension_type = case group_by.to_sym
                       when :metric then "metric"
                       when :submetric then "submetric"
                       when :category then "category"
                       else "metric"
                       end

      scope = InsightDetectionRollup
        .where(workspace_id: workspace_id, logit_margin_min: logit_margin_min)
        .where(subject_type: "Workspace", subject_id: workspace_id)
        .where(dimension_type: dimension_type)
        .where(posted_on: from.to_date..to.to_date)

      scope = scope.where(dimension_id: metric_ids) if metric_ids.present? && dimension_type == "metric"

      rows = scope
        .group(:dimension_id)
        .pluck(
          :dimension_id,
          Arel.sql("SUM(total_count)"),
          Arel.sql("SUM(positive_count)"),
          Arel.sql("SUM(negative_count)")
        )

      # Map dimension_ids to names
      names = case dimension_type
              when "metric"
                Metric.where(id: rows.map(&:first)).pluck(:id, :name).to_h
              when "submetric"
                Submetric.where(id: rows.map(&:first)).pluck(:id, :name).to_h
              when "category"
                SignalCategory.where(id: rows.map(&:first)).pluck(:id, :name).to_h
              else
                {}
              end

      rows.map do |(dim_id, tot, pos, neg)|
        total = tot.to_i
        {
          label: names[dim_id] || "Unknown",
          total: total,
          pos: pos.to_i,
          neg: neg.to_i,
          pos_rate: (total.zero? ? 0.0 : pos.to_f / total).round(6),
          neg_rate: (total.zero? ? 0.0 : neg.to_f / total).round(6),
          avg_logit: nil # Rollups don't store avg_logit
        }
      end.sort_by { |r| -r[:total] }
    end

    # Check if group rollups are available for a workspace
    def self.group_rollups_available?(workspace_id:, logit_margin_min:)
      return false if workspace_id.blank?
      InsightDetectionRollup
        .where(workspace_id: workspace_id, logit_margin_min: logit_margin_min, subject_type: "Group")
        .limit(ROLLUP_MIN_ROWS)
        .count >= ROLLUP_MIN_ROWS
    end

    # Fast group score using rollups (for compare_groups / group_gaps)
    # Returns score for a single group over a date range
    def self.group_score_from_rollups(workspace_id:, group_id:, from:, to:,
                                      metric_ids: nil, logit_margin_min: (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f)
      scope = InsightDetectionRollup
        .where(workspace_id: workspace_id, logit_margin_min: logit_margin_min)
        .where(subject_type: "Group", subject_id: group_id)
        .where(dimension_type: "metric")
        .where(posted_on: from.to_date..to.to_date)

      scope = scope.where(dimension_id: metric_ids) if metric_ids.present?

      totals = scope.pluck(
        Arel.sql("SUM(total_count)"),
        Arel.sql("SUM(positive_count)"),
        Arel.sql("SUM(negative_count)")
      ).first || [0, 0, 0]

      total = totals[0].to_i
      pos = totals[1].to_i
      neg = totals[2].to_i

      return nil if total < PRIVACY_FLOOR

      # Calculate score as average across detections
      # For culture scores, positive detections contribute 100, negative contribute 0
      # Score = (positive_count * 100) / total_count
      score = total.zero? ? nil : (pos.to_f * 100.0 / total).round(1)

      {
        total: total,
        positive: pos,
        negative: neg,
        score: score,
        pos_rate: (total.zero? ? 0.0 : pos.to_f / total).round(6),
        neg_rate: (total.zero? ? 0.0 : neg.to_f / total).round(6)
      }
    end

    # Fast multi-group comparison using rollups
    # Returns scores for multiple groups in one query
    def self.compare_groups_from_rollups(workspace_id:, group_ids:, from:, to:,
                                         metric_ids: nil, logit_margin_min: (ENV["LOGIT_MARGIN_THRESHOLD"] || "0.0").to_f)
      return [] if group_ids.blank?

      scope = InsightDetectionRollup
        .where(workspace_id: workspace_id, logit_margin_min: logit_margin_min)
        .where(subject_type: "Group", subject_id: group_ids)
        .where(dimension_type: "metric")
        .where(posted_on: from.to_date..to.to_date)

      scope = scope.where(dimension_id: metric_ids) if metric_ids.present?

      rows = scope
        .group(:subject_id)
        .pluck(
          :subject_id,
          Arel.sql("SUM(total_count)"),
          Arel.sql("SUM(positive_count)"),
          Arel.sql("SUM(negative_count)")
        )

      # Get group names and member counts
      group_info = Group
        .where(id: group_ids)
        .left_joins(:group_members)
        .group(:id)
        .pluck(:id, :name, Arel.sql("COUNT(group_members.id)"))
        .each_with_object({}) { |(id, name, count), h| h[id] = { name: name, member_count: count.to_i } }

      results = rows.map do |(group_id, tot, pos, neg)|
        total = tot.to_i
        info = group_info[group_id] || { name: "Unknown", member_count: 0 }

        # PRIVACY: Skip groups with < 3 members
        next nil if info[:member_count] < PRIVACY_FLOOR

        score = total.zero? ? nil : (pos.to_f * 100.0 / total).round(1)

        {
          group_id: group_id,
          name: info[:name],
          member_count: info[:member_count],
          total: total,
          score: score,
          pos_rate: (total.zero? ? 0.0 : pos.to_f / total).round(6)
        }
      end.compact

      results.sort_by { |r| -(r[:score] || 0) }
    end
  end
end



