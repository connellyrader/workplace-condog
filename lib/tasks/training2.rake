# lib/tasks/generate_descriptions.rake
require 'net/http'
require 'json'

namespace :training2 do
  desc "Generate positive and negative descriptions for all templates using Claude"
  task generate_descriptions: :environment do

    CLAUDE_API_KEY = ENV['ANTHROPIC_API_KEY']

    if CLAUDE_API_KEY.blank?
      puts "❌ Please set ANTHROPIC_API_KEY environment variable"
      exit
    end

    # Group templates by signal_category for batch processing
    templates_by_category = Template.all.group_by(&:signal_category)

    puts "🎯 Found #{templates_by_category.count} signal categories to process"
    puts "📊 Total templates: #{Template.count}"
    puts "="*80

    templates_by_category.to_a.reverse.each_with_index do |(signal_category, templates), idx|
      puts "\n[#{idx+1}/#{templates_by_category.count}] Processing: #{signal_category}"
      puts "  Templates in category: #{templates.count}"

      # Get all the context for this category
      metrics = templates.map(&:metric).uniq.join(", ")
      sub_metrics = templates.map(&:sub_metric).uniq.join(", ")

      # Generate descriptions for each template
      templates.each_with_index do |template, t_idx|
        # Skip if already has descriptions
        if template.positive_description.present? && template.negative_description.present?
          puts "  ✓ Template #{t_idx+1}: Already has descriptions, skipping"
          next
        end

        puts "  → Template #{t_idx+1}: #{template.signal}"

        # Generate positive description
        if template.positive_description.blank?
          pos_desc = generate_description(
            template,
            "Positive",
            metrics,
            sub_metrics,
            signal_category,
            CLAUDE_API_KEY
          )

          if pos_desc
            template.update!(positive_description: pos_desc)
            puts "    ✅ Generated positive description"
          else
            puts "    ❌ Failed to generate positive description"
          end

          sleep 0.5 # Rate limiting
        end

        # Generate negative description
        if template.negative_description.blank?
          neg_desc = generate_description(
            template,
            "Negative",
            metrics,
            sub_metrics,
            signal_category,
            CLAUDE_API_KEY
          )

          if neg_desc
            template.update!(negative_description: neg_desc)
            puts "    ✅ Generated negative description"
          else
            puts "    ❌ Failed to generate negative description"
          end

          sleep 0.5 # Rate limiting
        end
      end
    end

    puts "\n" + "="*80
    puts "✅ Description generation complete!"
    puts "📊 Templates with descriptions: #{Template.where.not(positive_description: nil).count}"
  end

  private

  def generate_with_claude(prompt, api_key)
    uri = URI('https://api.anthropic.com/v1/messages')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = api_key
    request['anthropic-version'] = '2023-06-01'

    request.body = {
      model: 'claude-opus-4-1-20250805',
      max_tokens: 1500,
      temperature: 0.7,
      messages: [
        {
          role: 'user',
          content: prompt
        }
      ]
    }.to_json

    begin
      response = http.request(request)
      result = JSON.parse(response.body)

      if result['error']
        puts "❌ API Error: #{result['error']['message']}"
        return nil
      end

      content = result.dig('content', 0, 'text')
      return nil unless content

      content.lines.map(&:strip).reject(&:blank?)
    rescue => e
      puts "❌ Error calling Claude API: #{e.message}"
      nil
    end
  end

  def validate_with_descriptions(examples, signal_category, polarity, templates, api_key)
    # Get one description for context
    sample_desc = templates.first.send("#{polarity.downcase}_description")

    prompt = <<~PROMPT
      Review these workplace messages labeled as #{signal_category}_#{polarity}.

      Here's what this signal means:
      #{sample_desc}

      For each message, determine if it:
      1. Clearly shows #{polarity.downcase} impact on workplace culture
      2. Specifically relates to #{signal_category}
      3. Matches the description above

      Messages to review:
      #{examples.map.with_index { |e, i| "#{i+1}. #{e}" }.join("\n")}

      For each message number, respond:
      - CORRECT if it clearly matches
      - INCORRECT if it doesn't match or is ambiguous
      - Give a brief reason

      Be strict - only mark CORRECT if unambiguous.
    PROMPT

    uri = URI('https://api.anthropic.com/v1/messages')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = api_key
    request['anthropic-version'] = '2023-06-01'

    request.body = {
      model: 'claude-opus-4-1-20250805',
      max_tokens: 1000,
      temperature: 0.3,
      messages: [
        {
          role: 'user',
          content: prompt
        }
      ]
    }.to_json

    begin
      response = http.request(request)
      result = JSON.parse(response.body)

      return result.dig('content', 0, 'text') || "No validation response"
    rescue => e
      "❌ Error during validation: #{e.message}"
    end
  end

  def generate_description(template, polarity, metrics, sub_metrics, signal_category, api_key)
    indicator = polarity == "Positive" ? template.positive_indicator : template.negative_indicator

    prompt = <<~PROMPT
      Create a clear description for identifying "#{template.signal}" (#{polarity}) in workplace messages.

      Context:
      - Parent metric: #{metrics}
      - Sub-metric: #{sub_metrics}
      - Signal category: #{signal_category}
      - Specific signal: #{template.signal}
      - Example indicator: #{indicator}

      Write a 2-3 sentence description that:
      1. Explains what #{polarity.downcase} "#{template.signal}" looks like in Slack/Teams messages
      2. Describes how this #{polarity.downcase} signal impacts workplace culture
      3. Gives specific behavioral markers to look for in messages
      4. Distinguishes it from similar but different signals

      Remember:
      - Positive = Improves/supports healthy workplace culture
      - Negative = Harms/degrades workplace culture

      Focus on observable message patterns and their cultural impact.
      Be specific and actionable for training data generation.
    PROMPT

    uri = URI('https://api.anthropic.com/v1/messages')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = api_key
    request['anthropic-version'] = '2023-06-01'

    request.body = {
      model: 'claude-opus-4-1-20250805',  # Use Haiku for cost efficiency
      max_tokens: 500,
      temperature: 0.3,
      messages: [
        {
          role: 'user',
          content: prompt
        }
      ]
    }.to_json

    begin
      response = http.request(request)
      result = JSON.parse(response.body)

      if result['error']
        puts "      ⚠️ API Error: #{result['error']['message']}"
        return nil
      end

      result.dig('content', 0, 'text')
    rescue => e
      puts "      ⚠️ Error: #{e.message}"
      nil
    end
  end
end
