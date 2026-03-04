require "slack-ruby-client"

module Insights
  class CandidatePersister
    Result = Struct.new(:created, :errors, keyword_init: true)

    DEFAULT_MODEL = ENV.fetch("INSIGHTS_LLM_MODEL", ENV.fetch("OPENAI_CHAT_MODEL", "gpt-4.1"))
    DEFAULT_TEMPERATURE = (ENV["INSIGHTS_LLM_TEMPERATURE"] || "0.3").to_f

    def initialize(candidates:, reference_time: Time.current, logger: Rails.logger, model: DEFAULT_MODEL, generate_summary: true, notify: true)
      @candidates = candidates
      @reference_time = reference_time
      @logger     = logger
      @model      = model
      @generate_summary = generate_summary
      @notify     = notify
      @created    = []
      @errors     = []
    end

    def persist!
      @candidates.each do |candidate|
        persist_candidate(candidate)
      end

      Result.new(created: @created, errors: @errors)
    end

    private

    attr_reader :logger, :reference_time, :model
    attr_reader :generate_summary, :notify

    def persist_candidate(candidate)
      template = candidate.trigger_template
      return unless template

      captured_at = candidate_reference_time(candidate)
      affected_members = affected_members_for(candidate)

      insight = Insight.create!(
        workspace: candidate.workspace,
        subject_type: candidate.subject_type,
        subject_id: candidate.subject_id,
        metric_id: metric_id_for(candidate),
        trigger_template: template,
        kind: insight_kind_from_template(template),
        polarity: polarity_from_template(template),
        severity: candidate.severity,
        window_start_at: candidate.window_range&.begin,
        window_end_at: candidate.window_range&.end,
        baseline_start_at: candidate.baseline_range&.begin,
        baseline_end_at: candidate.baseline_range&.end,
        affected_members: affected_members,
        affected_members_captured_at: captured_at,
        data_payload: build_payload(candidate, affected_members: affected_members, captured_at: captured_at),
        next_eligible_at: next_eligible_at(template, captured_at),
        state: "pending",
        created_at: captured_at,
        updated_at: captured_at
      )

      persist_driver_items(insight, candidate)

      summary = generate_summary_text(insight: insight, candidate: candidate)
      insight.update!(summary_title: summary[:title], summary_body: summary[:body])

      if notify
        Insights::Notifier.new(insight: insight, candidate: candidate).deliver!
      end

      logger.info("[Insights::CandidatePersister] created insight #{insight.id} (template=#{template.key})")

      @created << insight
      insight
    rescue => e
      logger.error("[Insights::CandidatePersister] candidate error #{e.class}: #{e.message}")
      @errors << { candidate: candidate, error: e }
      nil
    end

    def metric_id_for(candidate)
      case candidate.dimension_type
      when "metric"
        candidate.dimension_id
      when "submetric"
        Submetric.find_by(id: candidate.dimension_id)&.metric_id
      when "category"
        SignalCategory.includes(:submetric).find_by(id: candidate.dimension_id)&.submetric&.metric_id
      else
        nil
      end
    end

    def insight_kind_from_template(template)
      meta_kind = template.metadata.is_a?(Hash) ? template.metadata["insight_kind"] : nil
      return meta_kind if meta_kind && Insight::KINDS.include?(meta_kind)

      case template.direction
      when "positive" then "improvement"
      when "negative" then "risk_spike"
      else "exec_summary"
      end
    end

    def polarity_from_template(template)
      case template.direction
      when "negative" then "negative"
      when "positive" then "positive"
      else "mixed"
      end
    end

    def build_payload(candidate, affected_members:, captured_at: reference_time)
      {
        trigger_template: candidate.trigger_template&.key,
        dimension_type: candidate.dimension_type,
        dimension_id: candidate.dimension_id,
        stats: candidate.stats,
        severity: candidate.severity,
        affected_members: affected_members,
        affected_members_captured_at: captured_at
      }
    end

    def affected_members_for(candidate)
      case candidate.subject_type.to_s
      when "User"
        user = User.find_by(id: candidate.subject_id)
        return [] unless user

        payload = member_payload(
          user: user,
          account_type: workspace_account_type_for_user(candidate.workspace, user),
          source: "subject"
        )
        payload ? [payload] : []
      when "IntegrationUser"
        integration_user = IntegrationUser.includes(:user).find_by(id: candidate.subject_id)
        return [] unless integration_user

        payload = member_payload(
          user: integration_user.user,
          integration_user: integration_user,
          account_type: workspace_account_type_for_user(candidate.workspace, integration_user.user),
          source: "subject"
        )
        payload ? [payload] : []
      when "Group"
        group = Group.includes(integration_users: :user).find_by(id: candidate.subject_id)
        return [] unless group

        members = group.integration_users.map do |iu|
          member_payload(
            user: iu.user,
            integration_user: iu,
            account_type: workspace_account_type_for_user(candidate.workspace, iu.user),
            source: "group_member"
          )
        end.compact

        deduplicate_members(members)
      when "Workspace"
        workspace_admins(candidate.workspace)
      else
        []
      end
    end

    def workspace_admins(workspace)
      workspace.workspace_users.includes(:user).filter_map do |wu|
        next unless wu.user
        account_type = workspace_account_type(wu)
        next unless %w[owner admin].include?(account_type)

        member_payload(
          user: wu.user,
          account_type: account_type,
          source: "exec_summary"
        )
      end
    end

    def member_payload(user:, account_type:, source:, integration_user: nil)
      return nil unless user || integration_user

      {
        user_id: user&.id,
        integration_user_id: integration_user&.id,
        account_type: account_type,
        source: source,
        name: user_name(user, integration_user),
        email: user&.email.presence || integration_user&.email
      }.compact
    end

    def user_name(user, integration_user)
      return user.full_name if user&.respond_to?(:full_name) && user.full_name.present?
      return user.name if user&.respond_to?(:name) && user.name.present?

      integration_user&.real_name.presence || integration_user&.display_name
    end

    def deduplicate_members(members)
      seen = {}
      members.each_with_object([]) do |member, arr|
        key = [member[:user_id], member[:integration_user_id]]
        next if seen[key]

        seen[key] = true
        arr << member
      end
    end

    def workspace_account_type_for_user(workspace, user)
      return "no_account" unless user

      wu = workspace_user_for(workspace, user.id)
      return workspace_account_type(wu) if wu

      "no_account"
    end

    def workspace_account_type(workspace_user)
      return "owner" if workspace_user&.is_owner?
      case workspace_user&.role.to_s
      when "admin" then "admin"
      when "viewer" then "viewer"
      else "user"
      end
    end

    def workspace_user_for(workspace, user_id)
      return nil unless workspace && user_id

      @workspace_user_cache ||= {}
      cache = (@workspace_user_cache[workspace.id] ||= {})
      return cache[user_id] if cache.key?(user_id)

      cache[user_id] = WorkspaceUser.find_by(workspace_id: workspace.id, user_id: user_id)
    end

    def persist_driver_items(insight, candidate)
      items = build_driver_items(insight, candidate)
      InsightDriverItem.insert_all(items) if items.any?
    end

    def build_driver_items(insight, candidate)
      stats = candidate.stats || {}
      items = []

      if candidate.dimension_type && candidate.dimension_id
        items << driver_item_hash(
          insight_id: insight.id,
          driver_type: driver_type_for_dimension(candidate.dimension_type),
          driver_id: candidate.dimension_id,
          weight: 1.0
        )
      end

      Array(stats[:top_negative_submetrics]).each do |h|
        next unless h[:submetric_id]
        items << driver_item_hash(
          insight_id: insight.id,
          driver_type: "Submetric",
          driver_id: h[:submetric_id],
          weight: h[:share_of_negative_signals].to_f.nonzero? || h[:negative_rate].to_f
        )
      end

      Array(stats[:top_positive_submetrics]).each do |h|
        next unless h[:submetric_id]
        items << driver_item_hash(
          insight_id: insight.id,
          driver_type: "Submetric",
          driver_id: h[:submetric_id],
          weight: h[:share_of_positive_signals].to_f.nonzero? || h[:positive_rate].to_f
        )
      end

      Array(stats[:metric_negative_rate_deltas]).each do |h|
        next unless h[:metric_id]
        items << driver_item_hash(
          insight_id: insight.id,
          driver_type: "Metric",
          driver_id: h[:metric_id],
          weight: h[:delta_negative_rate].to_f
        )
      end

      Array(stats[:top_categories]).each do |h|
        category_id = h[:category_id] || h["category_id"] || h[:signal_category_id] || h["signal_category_id"]
        next unless category_id

        weight = h[:delta_rate] || h["delta_rate"] ||
                 h[:current_rate] || h["current_rate"] ||
                 h[:delta_negative_rate] || h["delta_negative_rate"] ||
                 h[:delta_positive_rate] || h["delta_positive_rate"] ||
                 0.1
        items << driver_item_hash(
          insight_id: insight.id,
          driver_type: "SignalCategory",
          driver_id: category_id,
          weight: weight.to_f
        )
      end

      contributing_messages(candidate, limit: 10).each do |msg|
        det_id = msg[:detection_id] || msg["detection_id"]
        next unless det_id
        items << driver_item_hash(
          insight_id: insight.id,
          driver_type: "Detection",
          driver_id: det_id,
          weight: 0.1
        )
      end

      items
    end

    def driver_type_for_dimension(dimension_type)
      case dimension_type.to_s
      when "category" then "SignalCategory"
      else dimension_type.to_s.classify
      end
    end

    def driver_item_hash(insight_id:, driver_type:, driver_id:, weight:)
      {
        insight_id: insight_id,
        driver_type: driver_type,
        driver_id: driver_id,
        weight: weight.to_f
      }
    end

    def next_eligible_at(template, reference = reference_time)
      days = template.cooldown_days.to_i
      return nil if days <= 0

      reference + days.days
    end

    def candidate_reference_time(candidate)
      stats = stats_hash(candidate)
      raw = stats[:snapshot_at] || stats["snapshot_at"]
      time =
        if raw.present?
          raw.is_a?(Time) ? raw : (Time.zone.parse(raw.to_s) rescue nil)
        end
      time ||= candidate.window_range&.end
      time ||= reference_time
      time
    end

    def generate_summary_text(insight:, candidate:, prompt_override: nil, fallback: true)
      template = candidate.trigger_template
      system_prompt = prompt_override.presence ||
                      PromptVersion.active_content("insight_template:#{template.key}") ||
                      template.system_prompt.presence ||
                      default_system_prompt

      user_payload = summary_payload(insight, candidate)
      request_content = <<~TEXT
        

        Return ONLY a JSON object with keys "title" and "body".
        - "title": short headline (<= 100 chars) with the subject + main metric/submetric/category. No numbers unless critical.
        - "body": plain-text, short and premium. It may include newlines and bullets using "- ".
        - Use plain language. Avoid jargon and data dumps.
        - Include at most TWO numbers total, only if they materially change interpretation. Prefer relative terms (rising, easing, stable).
        - Use timeframes like "last 2 weeks" instead of exact dates unless essential.
        - Highlight at most 3 key signals or drivers; do not list every metric.
        - Always include a brief "Why it matters" and 2-3 concrete "Next steps".
        - If messages are provided, add ONE short paraphrased example under "Example:".
        - If data is thin (low volume), label it as "early signal".
        Do not include markdown code fences.

        Data:
        #{JSON.pretty_generate(user_payload)}
      TEXT

      messages = [
        { role: "system", content: system_prompt },
        { role: "user", content: request_content }
      ]

      vector_store_id = ENV["OPENAI_VECTOR_STORE_ID"]
      service = AiChat::OpenaiChatService.new(
        model: model,
        temperature: DEFAULT_TEMPERATURE,
        vector_store_id: vector_store_id
      )
      raw = service.complete(messages: messages, vector_store_id: vector_store_id)
      parse_summary(raw)
    rescue => e
      logger.error("[Insights::CandidatePersister] summary generation failed #{e.class}: #{e.message}")
      raise unless fallback

      { title: fallback_title(candidate), body: fallback_body(candidate) }
    end

    def summary_payload(insight, candidate)
      template = candidate.trigger_template
      subject = subject_record(candidate)
      dimension = dimension_record(candidate)
      message_data = contributing_messages(candidate)
      stats_with_labels = labeled_stats(candidate.stats || {})
      metric = metric_record(candidate)

      {
        scope: template&.subject_scopes,
        entity_label: subject_name(subject) || insight.workspace.name,
        trigger_level: candidate.dimension_type,
        trigger_name: template&.name,
        trigger_description: template&.description,
        window_days: template&.window_days,
        baseline_days: template&.baseline_days,
        direction: template&.direction,
        workspace: insight.workspace.name,
        subject_type: candidate.subject_type,
        subject_id: candidate.subject_id,
        subject_name: subject_name(subject),
        dimension_type: candidate.dimension_type,
        dimension_id: candidate.dimension_id,
        dimension_name: dimension_name(dimension),
        metric_name: metric&.name,
        window_start_at: insight.window_start_at,
        window_end_at: insight.window_end_at,
        baseline_start_at: insight.baseline_start_at,
        baseline_end_at: insight.baseline_end_at,
        severity: insight.severity,
        stats: stats_with_labels,
        messages: message_data
      }
    end

    def subject_record(candidate)
      candidate.subject_type.to_s.safe_constantize&.find_by(id: candidate.subject_id)
    end

    def dimension_record(candidate)
      case candidate.dimension_type
      when "metric"
        Metric.find_by(id: candidate.dimension_id)
      when "submetric"
        Submetric.find_by(id: candidate.dimension_id)
      when "category"
        SignalCategory.find_by(id: candidate.dimension_id)
      else
        nil
      end
    end

    def metric_record(candidate)
      case candidate.dimension_type
      when "metric"
        Metric.find_by(id: candidate.dimension_id)
      when "submetric"
        Submetric.find_by(id: candidate.dimension_id)&.metric
      when "category"
        SignalCategory.find_by(id: candidate.dimension_id)&.submetric&.metric
      else
        nil
      end
    end

    def subject_name(subject)
      return nil unless subject
      return subject.name if subject.respond_to?(:name) && subject.name.present?
      return subject.full_name if subject.respond_to?(:full_name) && subject.full_name.present?

      if subject.is_a?(IntegrationUser)
        return subject.real_name if subject.real_name.present?
        return subject.display_name if subject.display_name.present?
        return subject.user&.full_name if subject.user&.full_name.present?
        return subject.user&.name if subject.user&.name.present?
      end

      nil
    end

    def dimension_name(dimension)
      return nil unless dimension
      dimension.respond_to?(:name) ? dimension.name : nil
    end

    def parse_summary(raw)
      json = JSON.parse(raw) rescue nil
      if json.is_a?(Hash) && json["title"].present?
        { title: json["title"].to_s.strip, body: json["body"].to_s.strip.presence || raw.to_s.strip }
      else
        { title: extract_title_from_text(raw), body: raw.to_s.strip }
      end
    end

    def extract_title_from_text(text)
      text.to_s.split(/[\n\.]/).first.to_s.strip.presence || "Insight"
    end

    def fallback_title(candidate)
      key = candidate.trigger_template&.key || "insight"
      "#{key.humanize} alert"
    end

    def fallback_body(candidate)
      "Insight generated for #{candidate.subject_type} #{candidate.subject_id} on #{candidate.dimension_type} #{candidate.dimension_id}"
    end

    def default_system_prompt
      <<~SYS
        You are a premium insights writer. Respond ONLY with JSON keys "title" and "body". Do not include markdown. The output must be short, clear, and decision-ready.

        CONTENT RULES
        - Lead with the meaning, not the math.
        - Use plain language; avoid jargon and internal metric keys.
        - Use at most TWO numbers total. Prefer relative wording (rising, easing, stable).
        - Use timeframes like "last 2 weeks" instead of exact dates unless essential.
        - If volume is low, call it an "early signal" and avoid strong claims.

        STRUCTURE (plain text, no markdown headings)
        1) One-sentence opener that states what changed and for whom.
        2) "Why it matters:" one sentence.
        3) "Key signals:" up to 3 bullets (focus on the most material drivers only).
        4) "Next steps:" 2-3 specific actions.
        5) "Example:" one short paraphrase if messages are present; otherwise omit.

        METRIC LANGUAGE
        - Use human labels (positive/negative rate, share, volume).
        - Reverse metrics (Burnout, Conflict, Execution Risk): higher % = more risk; lower = healthier.
        - Avoid listing every metric; choose the top 1-3 that explain the change.

        VECTOR STORE (if available)
        - If file_search is available, align with house style; paraphrase and keep it tight.
      SYS
    end

    # ---- message + signal helpers ----
    def contributing_messages(candidate, limit: nil)
      scope = detections_for_candidate(candidate).order(Arel.sql("#{Insights::QueryHelpers::POSTED_AT_SQL} DESC"))
      scope = scope.limit(limit.to_i) if limit

      seen = {}
      messages = []

      scope.each do |det|
        msg = det.message
        next unless msg
        key = msg.id || [msg.posted_at&.to_i, msg.text.to_s]
        next if seen[key]

        seen[key] = true
        messages << {
          detection_id: det.id,
          metric_id: det.metric_id,
          submetric_id: det.submetric_id,
          signal_category_id: det.signal_category_id,
          signal_subcategory_id: det.signal_subcategory_id,
          slack_ts: msg.slack_ts,
          channel_id: msg.channel.external_channel_id,
          text: fetch_and_scrub_message_text(msg)
        }
      end

      trim_message_payloads(messages)
    end

    def trim_message_payloads(messages)
      budget = ENV.fetch("INSIGHTS_LLM_MESSAGE_CHAR_BUDGET", "20000").to_i
      max_per = ENV.fetch("INSIGHTS_LLM_MESSAGE_CHAR_PER", "400").to_i
      min_per = ENV.fetch("INSIGHTS_LLM_MESSAGE_CHAR_MIN", "80").to_i

      total = messages.sum { |msg| msg[:text].to_s.length }
      return messages if budget <= 0 || total <= budget

      per = budget / [messages.size, 1].max
      per = [per, max_per].min
      per = [per, min_per].max if per >= min_per

      messages.map do |msg|
        text = msg[:text].to_s
        next msg if text.length <= per

        msg[:text] = "#{text[0, per]}…"
        msg[:text_truncated] = true
        msg[:text_truncated_chars] = text.length - per
        msg
      end
    end

    def labeled_stats(stats)
      stats = normalize_stats(stats)
      dup_stats =
        begin
          Marshal.load(Marshal.dump(stats))
        rescue
          stats.deep_dup rescue stats.dup
        end

      # Support both symbol and string keys
      neg_subs = dup_stats[:top_negative_submetrics] || dup_stats["top_negative_submetrics"] || []
      pos_subs = dup_stats[:top_positive_submetrics] || dup_stats["top_positive_submetrics"] || []
      metric_deltas = dup_stats[:metric_negative_rate_deltas] || dup_stats["metric_negative_rate_deltas"] || []
      top_categories = dup_stats[:top_categories] || dup_stats["top_categories"] || []

      submetric_ids = []
      Array(neg_subs).each { |h| submetric_ids << (h[:submetric_id] || h["submetric_id"]) if (h[:submetric_id] || h["submetric_id"]) }
      Array(pos_subs).each { |h| submetric_ids << (h[:submetric_id] || h["submetric_id"]) if (h[:submetric_id] || h["submetric_id"]) }
      submetric_ids.uniq!

      metric_ids = []
      Array(metric_deltas).each { |h| metric_ids << (h[:metric_id] || h["metric_id"]) if (h[:metric_id] || h["metric_id"]) }
      metric_ids.uniq!

      category_ids = []
      Array(top_categories).each { |h| category_ids << (h[:category_id] || h["category_id"]) if (h[:category_id] || h["category_id"]) }
      category_ids.uniq!

      submetric_lookup = submetric_ids.present? ? Submetric.where(id: submetric_ids).pluck(:id, :name).to_h : {}
      metric_lookup     = metric_ids.present? ? Metric.where(id: metric_ids).pluck(:id, :name).to_h : {}
      category_lookup   = category_ids.present? ? SignalCategory.where(id: category_ids).pluck(:id, :name).to_h : {}

      Array(neg_subs).each do |h|
        id = h[:submetric_id] || h["submetric_id"]
        name = submetric_lookup[id]
        h[:submetric_name] = name if name
        h["submetric_name"] = name if name
      end

      Array(pos_subs).each do |h|
        id = h[:submetric_id] || h["submetric_id"]
        name = submetric_lookup[id]
        h[:submetric_name] = name if name
        h["submetric_name"] = name if name
      end

      Array(metric_deltas).each do |h|
        id = h[:metric_id] || h["metric_id"]
        name = metric_lookup[id]
        h[:metric_name] = name if name
        h["metric_name"] = name if name
      end

      Array(top_categories).each do |h|
        id = h[:category_id] || h["category_id"]
        name = category_lookup[id]
        h[:category_name] = name if name
        h["category_name"] = name if name
      end

      dup_stats[:submetric_names] = submetric_lookup if submetric_lookup.present?
      dup_stats[:metric_names]    = metric_lookup if metric_lookup.present?
      dup_stats[:category_names]  = category_lookup if category_lookup.present?
      dup_stats["submetric_names"] = submetric_lookup if submetric_lookup.present?
      dup_stats["metric_names"]    = metric_lookup if metric_lookup.present?
      dup_stats["category_names"]  = category_lookup if category_lookup.present?

      dup_stats[:top_negative_submetrics] = neg_subs if neg_subs
      dup_stats[:top_positive_submetrics] = pos_subs if pos_subs
      dup_stats[:metric_negative_rate_deltas] = metric_deltas if metric_deltas
      dup_stats[:top_categories] = top_categories if top_categories
      dup_stats
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
      when "User"
        scope.joins(message: { integration_user: :user }).where(integration_users: { user_id: candidate.subject_id })
      when "IntegrationUser"
        scope.joins(:message).where(messages: { integration_user_id: candidate.subject_id })
      when "Group"
        scope.joins(message: { integration_user: { group_members: :group } }).where(group_members: { group_id: candidate.subject_id })
      when "Workspace"
        scope
      else
        scope.none
      end
    end

    def logit_margin_min_for(candidate)
      stats = stats_hash(candidate)
      raw = stats[:logit_margin_min] || stats["logit_margin_min"]
      raw = ENV.fetch("LOGIT_MARGIN_THRESHOLD", "0.0") if raw.nil?
      raw.to_f
    end

    def driver_dimension_ids(candidate)
      stats = stats_hash(candidate)
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

    def stats_hash(candidate)
      normalize_stats(candidate.stats || {})
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

    def fetch_and_scrub_message_text(message)
      raw = fetch_message_text(message) || message.text
      Messages::PiiScrubber.scrub(raw.to_s).strip
    end

    def fetch_message_text(message)
      integration = message.integration
      case integration.kind
      when "slack"
        fetch_slack_message_text(message, integration)
      when "microsoft_teams"
        fetch_teams_message_text(message, integration)
      else
        nil
      end
    end

    def fetch_slack_message_text(message, integration)
      client = slack_client_for_integration(integration)
      return nil unless client

      resp = client.conversations_history(
        channel: message.channel.external_channel_id,
        latest: message.slack_ts,
        inclusive: true,
        limit: 1
      )

      first = Array(resp["messages"]).first
      first && first["text"]
    rescue => e
      logger.warn("[Insights::CandidatePersister] Slack fetch failed for message #{message.id}: #{e.class} #{e.message}")
      nil
    end

    def fetch_teams_message_text(message, integration)
      iu = integration.integration_users.where.not(ms_refresh_token: nil).order(:id).first
      return message.text unless iu

      token = teams_token_for(iu)
      return message.text unless token

      team = integration.teams.first
      channel_id = message.channel.external_channel_id
      message_id = message.slack_ts

      url = "#{Teams::HistorySyncService::GRAPH_BASE}/teams/#{team.ms_team_id}/channels/#{channel_id}/messages/#{message_id}"
      resp = teams_http_get(url, token)
      body = resp && resp.dig("body", "content")

      text = strip_html(body.to_s).presence
      text || message.text
    rescue => e
      logger.warn("[Insights::CandidatePersister] Teams fetch failed for message #{message.id}: #{e.class} #{e.message}")
      nil
    end

    def teams_token_for(iu)
      if iu.ms_expires_at.present? && iu.ms_expires_at > 5.minutes.from_now
        iu.ms_access_token
      else
        refresh_teams_token(iu)
      end
    end

    def refresh_teams_token(iu)
      raise "No ms_refresh_token for integration_user #{iu.id}" if iu.ms_refresh_token.blank?

      uri  = URI(Integration::MS_TOKEN_URL)
      body = {
        client_id:     ENV.fetch("TEAMS_CLIENT_ID"),
        client_secret: ENV.fetch("TEAMS_CLIENT_SECRET"),
        grant_type:    "refresh_token",
        refresh_token: iu.ms_refresh_token
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Rails.env.development?

      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(body)
      res  = http.request(req)
      data = JSON.parse(res.body) rescue {}

      unless res.is_a?(Net::HTTPSuccess) && data["access_token"].present?
        logger.error "[Insights::CandidatePersister] Teams token refresh failed for iu=#{iu.id}: #{res.code} #{data}"
        return nil
      end

      iu.update!(
        ms_access_token:  data["access_token"],
        ms_refresh_token: data["refresh_token"].presence || iu.ms_refresh_token,
        ms_expires_at:    Time.current + data["expires_in"].to_i.seconds
      )

      iu.ms_access_token
    end

    def teams_http_get(url, token)
      conn = Faraday.new do |f|
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end

      res = conn.get(url) do |req|
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["Accept"]        = "application/json"
      end

      return res.body if res.status.between?(200, 299)

      logger.warn("[Insights::CandidatePersister] Teams GET #{url} failed: #{res.status} #{res.body}")
      nil
    end

    def strip_html(html)
      ActionView::Base.full_sanitizer.sanitize(html.to_s)
    end

    def slack_client_for_integration(integration)
      token_owner = IntegrationUser
        .where(integration_id: integration.id)
        .where.not(slack_history_token: nil)
        .first
      return nil unless token_owner&.slack_history_token.present?

      Slack::Web::Client.new(token: token_owner.slack_history_token)
    rescue => e
      logger.warn("[Insights::CandidatePersister] Slack client init failed: #{e.class} #{e.message}")
      nil
    end

  end
end
