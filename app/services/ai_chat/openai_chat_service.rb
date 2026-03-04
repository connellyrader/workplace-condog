# app/services/ai_chat/openai_chat_service.rb
# frozen_string_literal: true

module AiChat
  class OpenaiChatService
    DEFAULT_MODEL       = ENV.fetch("OPENAI_CHAT_MODEL", "gpt-5.2") # was gpt-4.1, changed to 5.2 on Jan 26 2026 by Lucas
    DEFAULT_TEMPERATURE = (ENV["OPENAI_TEMPERATURE"] || "0.2").to_f
    MAX_OUTPUT_TOKENS   = (ENV["OPENAI_MAX_OUTPUT_TOKENS"] || "800").to_i

    def initialize(model: DEFAULT_MODEL, temperature: DEFAULT_TEMPERATURE, request_id: nil, vector_store_id: ENV["OPENAI_VECTOR_STORE_ID"])
      @client      = OpenAI::Client.new
      @model       = model
      @temperature = temperature
      @request_id  = request_id || SecureRandom.uuid
      # Stored here so callers can set a default vector store for all completions
      @default_vector_store_id = vector_store_id.presence
    end

    # messages: [{role:, content:}, ...]
    #
    # If user is provided, this will:
    #   - enable custom tools (ToolRouter) + file_search
    #   - loop until all function calls are resolved
    # If user is nil, it just does a plain Responses call with no tools.
    def complete(messages:, user: nil, vector_store_id: nil)
      vector_store_id ||= @default_vector_store_id

      if user
        complete_with_tools(messages: messages, user: user)
      else
        basic_complete(messages: messages, vector_store_id: vector_store_id)
      end
    end

    # Streaming interface:
    # - with user: runs the tool loop using streaming Responses and yields tokens as they arrive
    #              and optionally notifies about tool activity
    # - without user: streams directly from Responses with no custom tools
    #
    # Callbacks:
    #   on_token.(delta_text)                          – each streamed text delta
    #   on_tool_status.(name, args_hash)               – before a tool is executed
    #   on_tool_result.(name, args_hash, result_json)  – after a tool returns JSON
    def stream_chat!(messages:, user: nil, on_token: nil, on_tool_status: nil, on_tool_result: nil, vector_store_id: nil, &block)
      on_token ||= block if block
      vector_store_id ||= @default_vector_store_id

      if user
        stream_with_tools(
          messages: messages,
          user: user,
          on_token: on_token,
          on_tool_status: on_tool_status,
          on_tool_result: on_tool_result
        )
      else
        stream_basic(messages: messages, on_token: on_token, vector_store_id: vector_store_id)
      end
    end

    private

    # ----- Shared params -----

    def base_response_params
      {
        model: @model,
        temperature: @temperature,
        max_output_tokens: MAX_OUTPUT_TOKENS
      }
    end

    def responses_tools
      AiChat::Tools.for_responses
    end

    def vector_store_params(vector_store_id)
      return {} if vector_store_id.blank?

      {
        tools: [{ type: "file_search", vector_store_ids: Array(vector_store_id) }],
        include: ["file_search_call.results"]
      }
    end

    # ----- Plain Responses (no custom tools) -----

    def basic_complete(messages:, vector_store_id: nil)
      params = base_response_params
        .merge(input: messages)
        .merge(vector_store_params(vector_store_id))

      resp   = @client.responses.create(parameters: params)
      extract_text_from_response(resp)
    rescue => e
      Rails.logger.error("[OpenAI responses.basic_complete error] rid=#{@request_id} #{e.class}: #{e.message}")
      raise
    end

    def stream_basic(messages:, on_token: nil, vector_store_id: nil, &block)
      on_token ||= block if block

      Rails.logger.info(
        "[OpenAI responses.stream_basic] rid=#{@request_id} model=#{@model} " \
        "messages_count=#{Array(messages).size}"
      )

      params = base_response_params
        .merge(input: messages)
        .merge(vector_store_params(vector_store_id))
        .merge(
          stream: proc do |chunk, _event|
            # Responses streaming uses event types like "response.output_text.delta"
            if chunk["type"] == "response.output_text.delta"
              delta = chunk["delta"].to_s
              on_token.call(delta) if on_token && !delta.empty?
            end
          end
        )

      @client.responses.create(parameters: params)
    rescue => e
      Rails.logger.error("[OpenAI responses.stream_basic error] rid=#{@request_id} #{e.class}: #{e.message}")
      raise
    end

    # ----- Full tool loop (custom functions + vector store) -----

    def complete_with_tools(messages:, user:)
      input_items = deep_dup_messages(messages)
      tools       = responses_tools

      loop do
        params = base_response_params.merge(
          input:   input_items,
          tools:   tools,
          # Include vector-store hits when file_search is used; model sees them directly.
          include: ["file_search_call.results"]
        )

        resp         = @client.responses.create(parameters: params)
        output_items = Array(resp["output"])

        # Custom tools: function calls that need ToolRouter
        function_calls = output_items.select { |item| item["type"] == "function_call" }

        # If there are no more function calls, we treat this as the final answer.
        if function_calls.empty?
          return extract_text_from_response(resp)
        end

        function_calls.each do |tool_call|
          name     = tool_call["name"]
          call_id  = tool_call["call_id"]
          raw_args = tool_call["arguments"] || "{}"

          args = begin
            JSON.parse(raw_args)
          rescue JSON::ParserError
            {}
          end

          begin
            tool_output = AiChat::ToolRouter.call(name, args, user: user)
          rescue => e
            Rails.logger.error("[OpenAI tool error] rid=#{@request_id} tool=#{name} #{e.class}: #{e.message}")
            tool_output = { error: e.message }.to_json
          end

          # Echo the model's function_call back into the input, then attach our result.
          # This matches the documented pattern:
          #   input_messages.append(tool_call)
          #   input_messages.append({ type: "function_call_output", call_id:, output: ... })
          input_items << tool_call
          input_items << {
            "type"    => "function_call_output",
            "call_id" => call_id,
            "output"  => tool_output.to_s
          }
        end

        # Loop around so the model can use those outputs.
      end
    rescue => e
      Rails.logger.error("[OpenAI responses.complete_with_tools error] rid=#{@request_id} #{e.class}: #{e.message}")
      raise
    end

    # Streaming version of the tool loop. Yields text deltas via on_token as the assistant
    # produces them, while still honoring tool calls and surfacing tool activity via callbacks.
    def stream_with_tools(messages:, user:, on_token: nil, on_tool_status: nil, on_tool_result: nil, &block)
      on_token ||= block if block

      input_items    = deep_dup_messages(messages)
      tools          = responses_tools
      tokens_emitted = false

      loop do
        Rails.logger.info(
          "[OpenAI responses.stream_with_tools] rid=#{@request_id} model=#{@model} " \
          "round_input_items=#{input_items.size}"
        )

        final_response = nil

        stream_proc = proc do |chunk, _event|
          chunk_type     = chunk["type"].to_s
          final_response = chunk["response"] if chunk["response"].is_a?(Hash)

          case chunk_type
          when "response.output_text.delta", "response.refusal.delta"
            delta = chunk["delta"].to_s
            if on_token && !delta.empty?
              tokens_emitted = true
              on_token.call(delta)
            end
          when "response.error"
            message = chunk.dig("error", "message") || "Streaming error"
            Rails.logger.error("[OpenAI responses.stream_with_tools error event] rid=#{@request_id} #{message}")
            raise StandardError, message
          end
        end

        params = base_response_params.merge(
          input:   input_items,
          tools:   tools,
          include: ["file_search_call.results"],
          stream:  stream_proc
        )

        api_response = @client.responses.create(parameters: params)
        resp = api_response || final_response
        break unless resp

         # Log a compact summary of the raw Responses payload so we can
         # inspect what (if anything) came back from the API.
         if resp.is_a?(Hash)
           items = Array(resp["output"])
           sample_types = items.first(3).map { |it| (it.is_a?(Hash) && it["type"]) || it.class.name }
           Rails.logger.info(
             "[OpenAI responses.stream_with_tools resp] rid=#{@request_id} keys=#{resp.keys} " \
             "output_size=#{items.size} sample_types=#{sample_types.inspect}"
           )
         else
           Rails.logger.info(
             "[OpenAI responses.stream_with_tools resp] rid=#{@request_id} non_hash_resp=#{resp.class.name}"
           )
         end

        output_items   = Array(resp["output"])
        function_calls = output_items.select { |item| item["type"] == "function_call" }

        # If there are no more function calls, treat this as final answer.
        if function_calls.empty?
          final_text = extract_text_from_response(resp)

          # If the API produced text but streaming never yielded deltas,
          # push the full text back through the token callback so the caller sees it.
          if !tokens_emitted && final_text.present? && on_token
            tokens_emitted = true
            on_token.call(final_text)
          end

          return final_text
        end

        function_calls.each do |tool_call|
          name     = tool_call["name"]
          call_id  = tool_call["call_id"]
          raw_args = tool_call["arguments"] || "{}"

          args = begin
            JSON.parse(raw_args)
          rescue JSON::ParserError
            {}
          end

          begin
            on_tool_status.call(name, args) if on_tool_status

            tool_output = AiChat::ToolRouter.call(name, args, user: user)
          rescue => e
            Rails.logger.error("[OpenAI tool error] rid=#{@request_id} tool=#{name} #{e.class}: #{e.message}")
            tool_output = { error: e.message }.to_json
          end

          begin
            on_tool_result.call(name, args, tool_output) if on_tool_result
          rescue => e
            Rails.logger.error("[OpenAI tool result callback error] rid=#{@request_id} tool=#{name} #{e.class}: #{e.message}")
          end

          input_items << tool_call
          input_items << {
            "type"    => "function_call_output",
            "call_id" => call_id,
            "output"  => tool_output.to_s
          }
        end

        # Loop so the model can incorporate tool outputs and continue streaming.
      end

      nil
    rescue => e
      Rails.logger.error("[OpenAI responses.stream_with_tools error] rid=#{@request_id} #{e.class}: #{e.message}")
      raise
    end

    # ----- Helpers -----

    # Pull all text from message-type outputs:
    # response["output"] is an array of items; message items have content[] with type:"output_text"/text:"..."
    def extract_text_from_response(resp)
      items = Array(resp["output"])

      Rails.logger.info("[OpenAI responses.extract_text] rid=#{@request_id} items_count=#{items.size}")

      text_chunks =
        items.flat_map do |item|
          content = item["content"]
          next [] unless content.is_a?(Array)

          content.filter_map do |c|
            if c.is_a?(Hash)
              if c["type"] == "output_text" && c["text"].present?
                c["text"].to_s
              elsif c["text"].present?
                c["text"].to_s
              end
            elsif c.is_a?(String)
              c
            end
          end
        end

      text_chunks.join
    end

    # Avoid mutating the caller's messages array when building up input_items
    def deep_dup_messages(messages)
      Marshal.load(Marshal.dump(messages))
    rescue
      messages.map { |m| m.dup }
    end
  end
end
