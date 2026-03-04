# frozen_string_literal: true

module AiChat
  # End-to-end runner for a single chat turn. Handles prompt building, tool loop,
  # synthesis, logging, retries, and broadcasting.
  class ChatRunner
    DEFAULT_MODEL = ENV.fetch("OPENAI_CHAT_MODEL", "gpt-5.2")
    ProviderRetryableError = Class.new(StandardError)

    def initialize(conversation:, user:, content:, options:, broadcaster:)
      @conversation    = conversation
      @user            = user
      @content         = content
      @options         = options || {}
      @broadcaster     = broadcaster

      @pending_inline_blocks = []
      @last_window           = nil
      @last_aggregates       = nil
      @last_comparison       = nil
      @period_a              = nil
      @period_b              = nil
    end

    def run
      client = OpenAI::Client.new
      tools  = AiChat::Tools.for_responses

      input_items = build_input_items
      tool_call_count = 0

      loop do
        response = responses_create_with_retry(
          client: client,
          parameters: {
            model: DEFAULT_MODEL,
            input: input_items,
            tools: tools,
            temperature: temperature,
            max_output_tokens: max_tokens,
            include: ["file_search_call.results"]
          }
        )

        output_items   = Array(response["output"])
        function_calls = output_items.select { |item| item["type"] == "function_call" }

        if function_calls.any?
          function_calls.each do |fc|
            tool_call_count += 1
            handle_tool_call(fc, input_items, client)
          end
          next
        end

        return synthesize_final(client: client, input_items: input_items, tool_call_count: tool_call_count)
      end
    rescue Faraday::BadRequestError => e
      log_ai(event: "provider.bad_request", message: e.message)
      broadcast(type: "error", message: "The AI provider rejected the request; please try rephrasing.")
      nil
    rescue => e
      log_ai(event: "runner.error", message: "#{e.class}: #{e.message}")
      broadcast(type: "error", message: "Chat failed. Please try again.")
      nil
    end

    private

    attr_reader :conversation, :user, :broadcaster

    # ---------- request building ----------

    def build_input_items
      prompt_text = system_prompt_text
      today = Time.zone.today
      tz    = Time.zone&.name || "UTC"

      base = [
        { role: "system", content: prompt_text },
        { role: "system", content: "You may call tools to fetch aggregates/timeseries/guidance. Do not output image markdown; charts are embedded by the app." },
        {
          role: "system",
          content: <<~TXT.strip
            TIME REFERENCE
            - Current date (#{tz}): #{today}
            - Interpret "today" as #{today}.
            - Interpret "this month", "last month", "this quarter", etc., relative to this date.
            - Interpret "last 30 days" as the rolling 30-day window ending on end_date (inclusive). If the user does not specify an end_date, use #{today}.
            - If the user says a month without a year (e.g., "December"), interpret it as the most recent month-end not in the future.
            - Avoid arbitrarily choosing older years like 2023 unless the user explicitly mentions that year.
          TXT
        },
        {
          role: "system",
          content: <<~TXT.strip
            CURRENT USER
            - First Name: #{conversation.user.first_name}
          TXT
        }
      ]

      ctx = AiChat::ContextBuilder.build(options: @options.deep_symbolize_keys)
      base << { role: "system", content: ctx } if ctx.present?

      history = conversation.messages.order(:created_at).last(8).map { |m| { role: m.role, content: m.content } }
      base + history
    end

    def system_prompt_text
      return conversation.system_prompt.presence || AiChat::Prompts.system if conversation.purpose == "prompt_test"

      AiChat::Prompts.system
    end

    # ---------- tool handling ----------

    def handle_tool_call(fc, input_items, client)
      name     = fc["name"]
      call_id  = fc["call_id"]
      raw_args = fc["arguments"] || "{}"
      args     = JSON.parse(raw_args) rescue {}

      args["workspace_id"] = conversation.workspace_id if conversation&.workspace_id.present?

      log_ai(event: "tool.call", message: name, extra: { args: safe_truncate(args.inspect, 500) })
      broadcast_status_for_tool(name, args)

      result_json = AiChat::ToolRouter.call(name, args, user: user)

      # Tool results can be large and often contain tokenized content; skip logging.

      parsed = JSON.parse(result_json) rescue {}
      if parsed.is_a?(Hash)
        @last_window = parsed["window"] if parsed["window"].is_a?(Hash)
        if parsed["aggregates"].is_a?(Array) && parsed["aggregates"].any?
          @last_aggregates = parsed["aggregates"]
        end
        if parsed["comparison"].is_a?(Array) && parsed["comparison"].any?
          @last_comparison = parsed["comparison"]
          @period_a = parsed["period_a"] if parsed["period_a"].is_a?(Hash)
          @period_b = parsed["period_b"] if parsed["period_b"].is_a?(Hash)
        end
      end

      input_items << fc
      input_items << {
        "type"    => "function_call_output",
        "call_id" => call_id,
        "output"  => result_json.to_s
      }
    end

    # ---------- synthesis ----------

    def synthesize_final(client:, input_items:, tool_call_count:)
      broadcast(
        type:    "status",
        phase:   "synthesizing",
        message: "Synthesizing insights for your leadership summary.",
        tool:    { name: nil, label: "Synthesis", kind: "synthesis" },
        context: {}
      )

      stream_attempts = 2
      text = nil
      tokens_emitted_any = false
      last_request_id = nil
      last_error = nil

      (1..stream_attempts).each do |attempt|
        result = perform_stream_attempt(client: client, input_items: input_items, attempt: attempt)
        tokens_emitted_any ||= result[:tokens_emitted]
        last_request_id ||= result[:request_id]
        last_error ||= result[:error_message]
        if result[:text].present?
          text = result[:text]
          break
        end
        if result[:error_message].present? && attempt < stream_attempts
          sleep(stream_retry_delay(attempt))
        end
      end

      if text.blank?
        non_stream = perform_nonstream_attempt(client: client, input_items: input_items)
        last_request_id ||= non_stream[:request_id]
        last_error ||= non_stream[:error_message]
        text = non_stream[:text] if non_stream[:text].present?
      end

      if text.blank? && @last_aggregates.present?
        text = build_insight_text(@last_aggregates, @last_window)
      end
      text = default_fallback_text(error_message: last_error) if text.blank?

      assistant_meta = {}
      assistant_meta["inline_blocks"] = @pending_inline_blocks if @pending_inline_blocks.present?
      assistant_meta["provider"] = { request_id: last_request_id, error: last_error }.compact if last_request_id || last_error

      assistant = conversation.messages.create!(
        role: "assistant",
        content: text,
        meta: assistant_meta,
        tool_call_count: tool_call_count
      )

      broadcast(type: "blocks", blocks: assistant_meta["blocks"]) if assistant_meta["blocks"].present?

      done_payload = {
        type: "done",
        content: assistant.content,
        message_id: assistant.id
      }
      done_payload[:inline_blocks] = assistant_meta["inline_blocks"] if assistant_meta["inline_blocks"].present?

      conversation.touch_activity!
      broadcast(done_payload)
      assistant
    end

    def perform_stream_attempt(client:, input_items:, attempt:)
      buffer              = +""
      active_output_index = nil
      final_response      = nil
      tokens_emitted      = false
      request_id          = nil
      error_message       = nil
      pending_buffer      = +""
      pending_count       = 0
      pending_streaming   = false
      pending_index       = nil
      stream_id           = SecureRandom.hex(6)
      stream_seq          = 0
      stream_started      = false

      start_stream = lambda do
        return if stream_started
        stream_started = true
        broadcast(type: "stream_start", stream_id: stream_id, attempt: attempt)
      end

      api_response = responses_create_with_retry(
        client: client,
        parameters: {
          model: DEFAULT_MODEL,
          input: input_items,
          temperature: temperature,
          max_output_tokens: max_tokens,
          stream: proc do |chunk, _event|
            begin
              chunk_type = chunk["type"].to_s
            rescue NoMethodError
              next
            end

            final_response = chunk["response"] if chunk["response"].is_a?(Hash)
            request_id ||= chunk.dig("response", "id")

            case chunk_type
            when "response.output_text.delta", "response.refusal.delta"
              delta = chunk["delta"].to_s
              next if delta.empty?

              oi = extract_output_index(chunk) || 0
              if active_output_index.nil? || oi > active_output_index
                active_output_index = oi
                buffer = +""
                # If we start seeing higher output indexes, discard any buffered tokens.
                pending_buffer = +""
                pending_count = 0
                pending_streaming = false
                pending_index = oi
              elsif oi < active_output_index
                next
              end

              buffer << delta
              tokens_emitted = true
              if pending_index != oi
                pending_index = oi
                pending_buffer = +""
                pending_count = 0
                pending_streaming = false
              end

              if pending_streaming
                start_stream.call
                stream_seq += 1
                broadcast(type: "token", token: delta, output_index: oi, stream_id: stream_id, seq: stream_seq)
              else
                pending_buffer << delta
                pending_count += 1
                if pending_count >= index0_stream_threshold
                  pending_streaming = true
                  if pending_buffer.present?
                    start_stream.call
                    stream_seq += 1
                    broadcast(type: "token", token: pending_buffer, output_index: oi, stream_id: stream_id, seq: stream_seq)
                  end
                  pending_buffer = +""
                end
              end

            when "response.error"
              error_message = chunk.dig("error", "message") || "Streaming error"
              log_ai(event: "synthesis.stream.error", message: error_message, extra: { request_id: request_id })
              broadcast(type: "error", message: "Chat failed while streaming. Please try again.")
            end
          end
        },
        attempts: 1
      )

      resp = api_response || final_response
      resp = resp.to_hash if resp.respond_to?(:to_hash)
      request_id ||= resp["id"] || resp.dig("response", "id") if resp.is_a?(Hash)

      if resp.is_a?(Hash) && resp["error"].present?
        error_message ||= resp.dig("error", "message") || resp["error"].to_s
        log_ai(event: "synthesis.stream.provider_error", message: error_message, extra: { request_id: request_id })
      end

      text = sanitize_model_text(buffer)
      if text.blank? && resp.present?
        extracted = sanitize_model_text(extract_text_from_response(resp))
        text = extracted if extracted.present?
      end

      { text: text, tokens_emitted: tokens_emitted, request_id: request_id, error_message: error_message }
    rescue => e
      log_ai(event: "synthesis.stream.exception", message: "#{e.class}: #{e.message}")
      broadcast(type: "error", message: "Chat failed while streaming. Please try again.")
      { text: nil, tokens_emitted: false, request_id: request_id, error_message: e.message }
    end

    def perform_nonstream_attempt(client:, input_items:)
      log_ai(event: "synthesis.nonstream.start", extra: { model: DEFAULT_MODEL })
      resp = responses_create_with_retry(
        client: client,
        parameters: {
          model: DEFAULT_MODEL,
          input: input_items,
          temperature: temperature,
          max_output_tokens: max_tokens
        }
      )
      request_id = resp["id"] if resp.is_a?(Hash)
      text = sanitize_model_text(extract_text_from_response(resp))
      { text: text, request_id: request_id, error_message: nil }
    rescue => e
      log_ai(event: "synthesis.nonstream.exception", message: "#{e.class}: #{e.message}")
      { text: nil, request_id: nil, error_message: e.message }
    end

    # ---------- helpers ----------

    def temperature
      (ENV["OPENAI_TEMPERATURE"] || "0.2").to_f
    end

    def max_tokens
      (ENV["OPENAI_MAX_OUTPUT_TOKENS"] || "800").to_i
    end

    def broadcast_status_for_tool(name, args)
      tool_name = name.to_s
      facets    = human_labels_from_args(args)

      payload = {
        type:  "status",
        phase: "tool_call",
        tool: {
          name:  tool_name,
          label: human_tool_label(tool_name),
          kind:  human_tool_kind(tool_name)
        },
        context: {
          facets: facets
        }
      }

      case tool_name
      when "fetch_category_aggregate"
        from = args["start_date"] || args.dig("window", "from")
        to   = args["end_date"]   || args.dig("window", "to")
        payload[:context][:range] = { from: from, to: to } if from || to
        payload[:message] =
          if from && to
            "Fetching aggregates for #{format_range(from, to)}."
          else
            "Fetching category aggregates."
          end

      when "fetch_period_comparison"
        a = args["period_a"] || {}
        b = args["period_b"] || {}
        a_from = a["start_date"] || a["from"]
        a_to   = a["end_date"]   || a["to"]
        b_from = b["start_date"] || b["from"]
        b_to   = b["end_date"]   || b["to"]

        payload[:context][:ranges] = {
          a: { from: a_from, to: a_to },
          b: { from: b_from, to: b_to }
        }
        payload[:message] = "Comparing signals between #{format_range(a_from, a_to)} and #{format_range(b_from, b_to)}."

      when "fetch_timeseries"
        from   = args["start_date"]
        to     = args["end_date"]
        metric = args["metric"] || "pos_rate"
        payload[:context][:range]  = { from: from, to: to } if from || to
        payload[:context][:metric] = metric
        payload[:message] =
          if from && to
            "Building #{metric} timeseries for #{from} → #{to}."
          else
            "Building timeseries."
          end
      else
        payload[:message] = "Running #{tool_name.tr('_', ' ')}."
      end

      broadcast(payload)
    rescue => e
      log_ai(event: "status.error", message: "#{name}: #{e.message}")
    end

    def human_labels_from_args(args)
      labels = []
      labels.concat Array(args["categories"])
      labels.concat Array(args["metric_names"])
      labels.concat Array(args["submetric_names"])
      labels.concat Array(args["subcategory_names"])
      labels.map { |s| s.to_s.strip }.reject(&:blank?).uniq
    end

    def format_range(from, to)
      if from && to
        "#{from} → #{to}"
      elsif from
        "from #{from}"
      elsif to
        "until #{to}"
      else
        "selected window"
      end
    end

    def human_tool_label(name)
      case name.to_s
      when "fetch_category_aggregate" then "Aggregates"
      when "fetch_period_comparison"  then "Period comparison"
      when "fetch_timeseries"         then "Timeseries"
      when "search_guidance"          then "Guidance lookup"
      when "batch_data_ops"           then "Batched data ops"
      else
        name.to_s.tr("_", " ").capitalize
      end
    end

    def human_tool_kind(name)
      case name.to_s
      when "fetch_category_aggregate" then "aggregate"
      when "fetch_period_comparison"  then "comparison"
      when "fetch_timeseries"         then "timeseries"
      when "search_guidance"          then "guidance"
      when "batch_data_ops"           then "batch"
      else
        "other"
      end
    end

    def extract_output_index(obj)
      obj["output_index"] ||
        obj.dig("output", "index") ||
        obj.dig("output_text", "output_index") ||
        obj.dig("output_text", "index") ||
        obj["index"]
    rescue
      nil
    end

    def extract_text_from_response(resp)
      items = Array(resp["output"])
      candidates = []

      items.each_with_index do |item, order|
        next unless item.is_a?(Hash)

        content = item["content"]
        next unless content.is_a?(Array)

        text_parts = content.filter_map do |c|
          c.is_a?(Hash) && c["type"] == "output_text" ? c["text"].to_s : nil
        end
        next if text_parts.empty?

        candidates << {
          text:  text_parts.join,
          index: extract_output_index(item),
          order: order
        }
      end

      best = candidates.max_by do |c|
        idx = c[:index]
        [idx.nil? ? -1 : idx.to_i, c[:order]]
      end

      best ? best[:text] : ""
    end

    def sanitize_model_text(text)
      t = text.to_s
      # t = t.gsub(/ *!\[[^\]]*\]\((?:sandbox:)?\/ai_chat\/sparkline[^)]*\) */i, " ")
      # t = t.gsub(/\(sandbox:\/([^)]+)\)/i, '(/\1)')
      # t = t.gsub(%r{https?://[^\s)]+/ai_chat/sparkline[^\s)]*}i, "")

      # # Guardrails: add missing spacing in prose while preserving code blocks/inline code.
      # code_blocks = []
      # inline_codes = []
      # t = t.gsub(/```[\s\S]*?```/) do |m|
      #   key = "%%AI_CODEBLOCK_#{code_blocks.length}%%"
      #   code_blocks << m
      #   key
      # end
      # t = t.gsub(/`[^`\n]+`/) do |m|
      #   key = "%%AI_CODEINLINE_#{inline_codes.length}%%"
      #   inline_codes << m
      #   key
      # end

      # # Insert a space when letters run into numbers, and after ) or : before numbers.
      # t = t.gsub(/([A-Za-z])(\d)/, '\1 \2')
      # t = t.gsub(/([):])(\d)/, '\1 \2')
      # # Insert a space between words that got jammed together (e.g., "meansThat" -> "means That").
      # t = t.gsub(/([a-z]{2,})([A-Z][a-z])/, '\1 \2')
      # # Add a space after sentence-ending punctuation when followed by a capital letter.
      # t = t.gsub(/([.!?])([A-Z])/, '\1 \2')
      # # Add a space after commas in dates like "July 31,2025".
      # t = t.gsub(/([A-Za-z]+ \d{1,2}),(?=\d{4}\b)/, '\1, ')
      # # Add a space after commas before letters (e.g., "foo,bar" -> "foo, bar").
      # t = t.gsub(/,([A-Za-z])/, ', \1')
      # # If a heading runs into the next sentence, split it onto a new line.
      # t = t.gsub(
      #   /(^|\n)(\#{1,6} [^\n]+?)\s+(As|A|An|The|That|This|These|Those|In|On|At|By|From|Here|Now|We|You|It|They|There|Overall|Meanwhile|However|So|To|For|If|When|While)\b/,
      #   "\\1\\2\n\\3"
      # )

      # t = t.gsub(/%%AI_CODEBLOCK_(\d+)%%/) { |m| code_blocks[Regexp.last_match(1).to_i] || "" }
      # t.gsub(/%%AI_CODEINLINE_(\d+)%%/) { |m| inline_codes[Regexp.last_match(1).to_i] || "" }
    end

    def default_fallback_text(error_message: nil)
      return "We had trouble streaming the full answer. Please try again in a moment." if error_message.blank?
      "The AI provider returned an error while generating your answer. Please try again in a moment."
    end

    def build_insight_text(agg, window)
      lines = []
      if window&.dig("from") && window&.dig("to")
        lines << "From #{window["from"]} to #{window["to"]}, here’s what stands out:"
      else
        lines << "Here’s what stands out in the selected window:"
      end

      agg.sort_by { |r| -r["total"].to_i }.first(3).each do |r|
        pr = (r["pos_rate"].to_f * 100).round(1)
        nr = (r["neg_rate"].to_f * 100).round(1)
        lines << "• **#{r["label"] || r["category"]}** — total=#{r["total"]} (pos=#{pr}%, neg=#{nr}%)."
      end
      lines << "Consider the chart(s) below and adjust the date window or facets for deeper diagnosis."
      lines.join("\n")
    end

    def broadcast(payload)
      broadcaster.call(payload)
    end

    def log_ai(event:, message: nil, extra: {})
      msg = "[AI_CHAT] event=#{event} conv=#{conversation.id} user=#{user.id}"
      msg += " msg=#{message}" if message
      msg += " extra=#{extra.inspect}" if extra.present?
      Rails.logger.info(msg)
    end

    def responses_create_with_retry(client:, parameters:, attempts: 2, backoff: 0.4)
      last_error = nil
      attempts.times do |idx|
        begin
          resp = client.responses.create(parameters: parameters)
          resp_hash = resp.respond_to?(:to_hash) ? resp.to_hash : resp
          if resp_hash.is_a?(Hash) && resp_hash["error"].present?
            message = resp_hash.dig("error", "message") || resp_hash["error"].to_s
            raise ProviderRetryableError, message
          end
          return resp
        rescue ProviderRetryableError, Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ServerError, Faraday::SSLError => e
          last_error = e
          if idx + 1 < attempts
            sleep(backoff * (idx + 1))
            next
          end
          raise last_error
        end
      end
    end

    def stream_retry_delay(attempt)
      0.4 * attempt
    end

    def index0_stream_threshold
      threshold = (ENV["AI_CHAT_STREAM_INDEX0_THRESHOLD"] || "8").to_i
      threshold = 8 if threshold <= 0
      threshold
    end


    def safe_truncate(str, limit)
      return str if str.to_s.length <= limit
      "#{str[0, limit]}…"
    end
  end
end
