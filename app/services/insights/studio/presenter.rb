module Insights
  module Studio
    class Presenter
      def decorate_candidates(candidates, snapshot_at: nil, run_id: nil, include_evidence: true)
        return [] if candidates.blank?

        integration_user_ids = candidates.select { |c| c.subject_type.to_s == "IntegrationUser" }.map(&:subject_id).uniq
        user_subject_ids = candidates.select { |c| c.subject_type.to_s == "User" }.map(&:subject_id).uniq
        group_ids = candidates.select { |c| c.subject_type.to_s == "Group" }.map(&:subject_id).uniq
        workspace_ids = candidates.select { |c| c.subject_type.to_s == "Workspace" }.map(&:subject_id).uniq

        metric_ids = []
        submetric_ids = []
        category_ids = []
        driver_submetric_ids = []
        driver_category_ids = []

        candidates.each do |c|
          case c.dimension_type.to_s
          when "metric" then metric_ids << c.dimension_id
          when "submetric" then submetric_ids << c.dimension_id
          when "category" then category_ids << c.dimension_id
          end

          stats = c.stats || {}
          Array(stats[:top_negative_submetrics] || stats["top_negative_submetrics"]).each do |h|
            id = h[:submetric_id] || h["submetric_id"]
            driver_submetric_ids << id if id
          end
          Array(stats[:top_positive_submetrics] || stats["top_positive_submetrics"]).each do |h|
            id = h[:submetric_id] || h["submetric_id"]
            driver_submetric_ids << id if id
          end
          Array(stats[:top_categories] || stats["top_categories"]).each do |h|
            id = h[:category_id] || h["category_id"] || h[:signal_category_id] || h["signal_category_id"]
            driver_category_ids << id if id
          end
        end

        integration_users = integration_user_ids.any? ? IntegrationUser.where(id: integration_user_ids).includes(:user).index_by(&:id) : {}
        user_ids = (integration_users.values.filter_map(&:user_id) + user_subject_ids).uniq
        users = user_ids.any? ? User.where(id: user_ids).index_by(&:id) : {}
        groups = group_ids.any? ? Group.where(id: group_ids).index_by(&:id) : {}
        workspaces = workspace_ids.any? ? Workspace.where(id: workspace_ids).index_by(&:id) : {}
        metrics = metric_ids.any? ? Metric.where(id: metric_ids).index_by(&:id) : {}
        submetric_ids = (submetric_ids + driver_submetric_ids).compact.uniq
        category_ids = (category_ids + driver_category_ids).compact.uniq
        submetrics = submetric_ids.any? ? Submetric.where(id: submetric_ids).index_by(&:id) : {}
        categories = category_ids.any? ? SignalCategory.where(id: category_ids).index_by(&:id) : {}

        candidates.map.with_index do |candidate, idx|
          stats = candidate.stats || {}
          stats =
            begin
              Marshal.load(Marshal.dump(stats))
            rescue
              stats.deep_dup rescue stats.dup
            end
          Array(stats[:top_negative_submetrics] || stats["top_negative_submetrics"]).each do |h|
            id = h[:submetric_id] || h["submetric_id"]
            name = submetrics[id]&.name
            h[:submetric_name] = name if name
            h["submetric_name"] = name if name
          end
          Array(stats[:top_positive_submetrics] || stats["top_positive_submetrics"]).each do |h|
            id = h[:submetric_id] || h["submetric_id"]
            name = submetrics[id]&.name
            h[:submetric_name] = name if name
            h["submetric_name"] = name if name
          end
          Array(stats[:top_categories] || stats["top_categories"]).each do |h|
            id = h[:category_id] || h["category_id"] || h[:signal_category_id] || h["signal_category_id"]
            name = categories[id]&.name
            h[:category_name] = name if name
            h["category_name"] = name if name
          end
          evidence = include_evidence ? evidence_messages_for(candidate) : nil
          evidence_count = include_evidence ? Array(evidence).size : evidence_count_for(candidate)
          summary_title = stats[:summary_title] || stats["summary_title"]
          summary_body = stats[:summary_body] || stats["summary_body"]
          subject_label =
            case candidate.subject_type.to_s
            when "IntegrationUser"
              integration_user = integration_users[candidate.subject_id]
              integration_user&.display_name ||
                integration_user&.real_name ||
                integration_user&.user&.full_name ||
                integration_user&.user&.name ||
                "User #{candidate.subject_id}"
            when "User"
              users[candidate.subject_id]&.full_name ||
                users[candidate.subject_id]&.name ||
                "User #{candidate.subject_id}"
            when "Group" then groups[candidate.subject_id]&.name || "Group #{candidate.subject_id}"
            when "Workspace" then workspaces[candidate.subject_id]&.name || "Workspace #{candidate.subject_id}"
            else candidate.subject_type.to_s
            end

          dimension_label =
            case candidate.dimension_type.to_s
            when "metric" then metrics[candidate.dimension_id]&.name || "Metric #{candidate.dimension_id}"
            when "submetric" then submetrics[candidate.dimension_id]&.name || "Submetric #{candidate.dimension_id}"
            when "category" then categories[candidate.dimension_id]&.name || "Category #{candidate.dimension_id}"
            when "summary" then candidate.trigger_template&.name || "Executive summary"
            else candidate.dimension_id
            end

          snapshot_value = stats[:snapshot_at] || stats["snapshot_at"] || snapshot_at
          snapshot_value = parse_snapshot(snapshot_value)

          {
            id: idx + 1,
            run_id: run_id,
            workspace_id: candidate.workspace.id,
            snapshot_at: snapshot_value&.iso8601,
            trigger_template_id: candidate.trigger_template&.id,
            trigger_key: candidate.trigger_template&.key,
            trigger_name: candidate.trigger_template&.name,
            primary: candidate.trigger_template&.primary?,
            direction: candidate.trigger_template&.direction,
            subject_type: candidate.subject_type,
            subject_id: candidate.subject_id,
            subject_label: subject_label,
            dimension_type: candidate.dimension_type,
            dimension_id: candidate.dimension_id,
            dimension_label: dimension_label,
            severity: candidate.severity,
            direction: candidate.trigger_template&.direction,
            window_range: range_payload(candidate.window_range),
            baseline_range: range_payload(candidate.baseline_range),
            stats: stats,
            evidence_messages: evidence,
            evidence_count: evidence_count,
            summary_title: summary_title,
            summary_body: summary_body
          }
        end
      end

      def build_candidate_rows(candidates, payloads, selection)
        return [] if candidates.blank?

        payload_map = payloads.index_by { |payload| payload_key(payload) }
        accepted_keys = {}
        rejected_keys = {}

        Array(selection&.accepted).each { |c| accepted_keys[candidate_key(c)] = true }
        Array(selection&.rejected).each do |entry|
          rejected_keys[candidate_key(entry[:candidate])] = entry[:reason]
        end

        max_severity = candidates.map { |c| c.severity.to_f }.max.to_f
        sorted = candidates.sort_by do |candidate|
          window_end = candidate.window_range&.end || Time.at(0)
          [-window_end.to_i, -candidate.severity.to_f]
        end

        sorted.map.with_index do |candidate, idx|
          key = candidate_key(candidate)
          payload = payload_map[key]
          next unless payload

          stats = (candidate.stats || {}).with_indifferent_access
          deliverable = stats[:deliverable]
          delivery_reason = stats[:delivery_reason]

          delta_value = candidate_delta(candidate)
          delta_display = format_delta(delta_value)
          severity_pct = max_severity.positive? ? ((candidate.severity.to_f / max_severity.to_f) * 100.0) : 0.0
          status = accepted_keys[key] ? "accepted" : "filtered"
          window_end_label = payload_window_end_date(payload)

          {
            rank: idx + 1,
            metric_label: payload[:dimension_label],
            subject_label: payload[:subject_label],
            severity: candidate.severity.to_f,
            severity_pct: severity_pct,
            delta_display: delta_display,
          evidence_count: payload[:evidence_count] || Array(payload[:evidence_messages]).size,
            status: status,
            status_reason: rejected_keys[key],
            deliverable: deliverable,
            delivery_reason: delivery_reason,
            window_end_label: window_end_label,
            payload: payload
          }
        end.compact
      end

      def evidence_messages(candidate, limit: nil, offset: nil)
        evidence_messages_for(candidate, limit: limit, offset: offset)
      end

      def evidence_count(candidate)
        evidence_count_for(candidate)
      end

      private

      def candidate_delta(candidate)
        stats = candidate.stats || {}
        direction = candidate.trigger_template&.direction.to_s

        if direction == "positive"
          stats[:delta_positive_rate] || stats["delta_positive_rate"] || stats[:delta_rate] || stats["delta_rate"]
        elsif direction == "negative"
          stats[:delta_negative_rate] || stats["delta_negative_rate"] || stats[:delta_rate] || stats["delta_rate"]
        else
          stats[:delta_rate] || stats["delta_rate"] || stats[:delta_negative_rate] || stats[:delta_positive_rate]
        end
      end

      def format_delta(value)
        return "-" if value.nil?
        pct = value.to_f * 100.0
        sign = pct.positive? ? "+" : ""
        "#{sign}#{format('%.1f', pct)}%"
      end

      def candidate_key(candidate)
        [
          candidate.trigger_template&.id,
          candidate.subject_type.to_s,
          candidate.subject_id,
          candidate.dimension_type.to_s,
          candidate.dimension_id,
          window_end_key(candidate.window_range)
        ].join(":")
      end

      def payload_key(payload)
        [
          payload[:trigger_template_id],
          payload[:subject_type],
          payload[:subject_id],
          payload[:dimension_type],
          payload[:dimension_id],
          payload_window_end_key(payload)
        ].join(":")
      end

      def window_end_key(range)
        range&.end&.to_date&.to_s
      end

      def payload_window_end_key(payload)
        range = payload[:window_range] || payload["window_range"]
        end_at = range && (range[:end_at] || range["end_at"])
        return nil if end_at.blank?
        Time.zone.parse(end_at.to_s).to_date.to_s
      rescue
        end_at.to_s
      end

      def payload_window_end_date(payload)
        range = payload[:window_range] || payload["window_range"]
        end_at = range && (range[:end_at] || range["end_at"])
        return nil if end_at.blank?
        Time.zone.parse(end_at.to_s).to_date.to_s
      rescue
        end_at.to_s
      end

      def parse_snapshot(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return nil if value.blank?
        Time.zone.parse(value.to_s)
      rescue
        nil
      end

      def range_payload(range)
        return nil unless range
        {
          start_at: range.begin&.iso8601,
          end_at: range.end&.iso8601
        }
      end

      def evidence_messages_for(candidate, limit: nil, offset: nil)
        seen = {}
        results = []
        skipped = offset.to_i
        skipped = 0 if skipped.negative?

        scope = detections_for_candidate(candidate).order(Arel.sql("#{Insights::QueryHelpers::POSTED_AT_SQL} DESC"))
        if limit
          base = limit.to_i
          base = 0 if base.negative?
          offset_val = offset.to_i
          offset_val = 0 if offset_val.negative?
          fetch_limit = (base + offset_val) * 5
          scope = scope.limit(fetch_limit) if fetch_limit.positive?
        end

        scope.each do |det|
          msg = det.message
          next unless msg
          key = msg.id || [msg.posted_at&.to_i, msg.text.to_s]
          next if seen[key]

          seen[key] = true
          if skipped.positive?
            skipped -= 1
            next
          end
          results << {
            detection_id: det.id,
            posted_at: msg&.posted_at&.iso8601,
            channel_id: msg&.channel&.external_channel_id,
            text: Messages::PiiScrubber.scrub(msg&.text.to_s).strip
          }
          break if limit && results.size >= limit
        end

        results
      end

      def evidence_count_for(candidate)
        detections_for_candidate(candidate).distinct.count(:message_id)
      end

      def detections_for_candidate(candidate)
        workspace = candidate.workspace
        window_range = candidate.window_range
        logit_margin_min = logit_margin_min_for(candidate)
        submetric_ids, category_ids = driver_dimension_ids(candidate)

        scope = Detection.for_workspace(workspace.id)
        scope = scope.with_scoring_policy
        scope = scope.where(metric_id: candidate.dimension_id) if candidate.dimension_type == "metric"
        scope = scope.where(submetric_id: candidate.dimension_id) if candidate.dimension_type == "submetric"
        scope = scope.where(signal_category_id: candidate.dimension_id) if candidate.dimension_type == "category"
        if window_range
          posted_at_sql = Insights::QueryHelpers::POSTED_AT_SQL
          scope = scope.joins(:message).where("#{posted_at_sql} BETWEEN ? AND ?", window_range.begin, window_range.end)
        end

        scope = filter_by_driver_dimensions(scope, submetric_ids: submetric_ids, category_ids: category_ids)

        case candidate.subject_type.to_s
        when "IntegrationUser"
          scope.joins(:message).where(messages: { integration_user_id: candidate.subject_id })
        when "User"
          scope
            .joins(message: :integration_user)
            .where("integration_users.user_id = :id", id: candidate.subject_id)
        when "Group"
          scope.joins(message: { integration_user: { group_members: :group } }).where(group_members: { group_id: candidate.subject_id })
        when "Workspace"
          scope
        else
          scope.none
        end
      end

      def logit_margin_min_for(candidate)
        stats = normalize_stats(candidate.stats || {})
        raw = stats[:logit_margin_min] || stats["logit_margin_min"]
        raw = ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0") if raw.nil?
        raw.to_f
      end

      def driver_dimension_ids(candidate)
        stats = normalize_stats(candidate.stats || {})
        neg_subs = Array(stats[:top_negative_submetrics])
        pos_subs = Array(stats[:top_positive_submetrics])
        categories = Array(stats[:top_categories])

        submetric_ids = (neg_subs + pos_subs).filter_map { |h| h[:submetric_id] || h["submetric_id"] }
        category_ids = categories.filter_map { |h| h[:category_id] || h["category_id"] || h[:signal_category_id] || h["signal_category_id"] }

        case candidate.dimension_type.to_s
        when "submetric"
          submetric_ids << candidate.dimension_id
        when "category"
          category_ids << candidate.dimension_id
        end

        [submetric_ids.uniq, category_ids.uniq]
      end

      def normalize_stats(stats)
        if stats.respond_to?(:to_unsafe_h)
          stats = stats.to_unsafe_h
        elsif stats.respond_to?(:to_h) && !stats.is_a?(Hash)
          stats = stats.to_h
        end
        stats.with_indifferent_access
      end

      def filter_by_driver_dimensions(scope, submetric_ids:, category_ids:)
        submetric_ids = Array(submetric_ids).compact.uniq
        category_ids = Array(category_ids).compact.uniq

        return scope if submetric_ids.empty? && category_ids.empty?
        return scope.where(submetric_id: submetric_ids) if category_ids.empty?
        return scope.where(signal_category_id: category_ids) if submetric_ids.empty?

        scope.where(submetric_id: submetric_ids).or(scope.where(signal_category_id: category_ids))
      end
    end
  end
end
