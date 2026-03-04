class SignalsController < ApplicationController
  require 'httparty'

  def analyze
    start_time = Time.now
    @model = 'mistral'
    server_ip = '165.22.234.220'

    message_limit = 5
    offset = 25

    @messages = Message.order(id: :desc).limit(message_limit).offset(offset)

    signals = [
      { name: "Ideation", definition: "Mentions creating new ideas, brainstorming, innovation, or creative problem-solving." },
      { name: "Participation", definition: "States involvement or engagement in tasks, activities, decisions, or collaboration." },
      { name: "Alignment", definition: "States synchronization or alignment of team efforts, clear goals, or actions directed in a shared direction." },
      { name: "Cohesion", definition: "Mentions team unity, togetherness, belonging, or community." },
      { name: "Direction", definition: "Mentions clear goal-setting, objectives, decisions, or an explicitly defined purposeful path forward." },
      { name: "Recognition", definition: "Mentions of acknowledging, appreciating, or rewarding someone's contributions or achievements."}
    ]

    @analysis_results = []

    @messages.each do |msg|
      signals.each do |signal|
        prompt = <<~PROMPT
          Analyze the following Slack message strictly for signals matching the provided definition.
          Only identify a signal if the message explicitly and clearly matches the definition.
          If the message does not explicitly match, return no signals.

          Signal: "#{signal[:name]}"
          Definition: "#{signal[:definition]}"

          Confidence Levels:
          - High: The message explicitly matches the signal without ambiguity.
          - Medium: The message matches the signal with minor ambiguity.
          - Low: The message possibly matches the signal but contains significant ambiguity.

          *** BEGIN MESSAGE ***
          MESSAGE ID: #{msg.id}
          Text: #{msg.text.strip.gsub(/\s+/, ' ')}
          *** END MESSAGE ***

          Respond only with the following JSON structure:

          {
            "message_id": #{msg.id},
            "signal_found": true/false,
            "signal_name": "#{signal[:name]}",
            "evidence": "exact quoted text from message" (empty string if no signal found),
            "reasoning": "concise explanation, strictly based on explicit match",
            "confidence": "low" | "medium" | "high" | "none"
          }
        PROMPT

        response = HTTParty.post(
          "http://#{server_ip}:11434/api/generate",
          headers: { 'Content-Type' => 'application/json' },
          body: { model: @model, prompt: prompt, stream: false }.to_json
        )

        parsed_body = JSON.parse(response.body) rescue {}
        response_text = parsed_body["response"] || ""

        begin
          json_start = response_text.index('{')
          json_end = response_text.rindex('}')
          signal_data = {}

          if json_start && json_end
            json_string = response_text[json_start..json_end]
            signal_data = JSON.parse(json_string)
          else
            signal_data = { "signal_found" => false }
          end
        rescue JSON::ParserError => e
          Rails.logger.error("JSON parsing failed for message ID #{msg.id}: #{e.message}")
          signal_data = { "signal_found" => false }
        end

        @analysis_results << {
          message_id: msg.id,
          message_text: msg.text.strip,
          signal_name: signal[:name],
          evidence: signal_data["signal_found"] ? signal_data["evidence"] : "none",
          reasoning: signal_data["signal_found"] ? signal_data["reasoning"] : "No explicit match found.",
          confidence: signal_data["signal_found"] ? signal_data["confidence"] : "none"
        }
      end
    end

    @execution_time = Time.now - start_time
  end
end
