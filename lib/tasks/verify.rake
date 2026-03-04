# lib/tasks/verify_training.rake
require 'net/http'
require 'json'

namespace :verify do
  desc "Verify training data accuracy with Claude using template context"
  task verify_examples: :environment do

    CLAUDE_API_KEY = ENV['ANTHROPIC_API_KEY']

    if CLAUDE_API_KEY.blank?
      puts "❌ Please set ANTHROPIC_API_KEY environment variable"
      exit
    end

    # First, add the verified column if it doesn't exist
    unless Example.column_names.include?('verified')
      puts "📝 Adding verified column to examples table..."
      ActiveRecord::Base.connection.execute <<-SQL
        ALTER TABLE examples
        ADD COLUMN IF NOT EXISTS verified BOOLEAN DEFAULT NULL;
      SQL
      Example.reset_column_information
    end

    # Clear existing verifications
    puts "🗑️  Clearing existing verifications..."
    Example.update_all(verified: nil)

    # Get counts
    total_examples = Example.count
    total_templates = Template.count

    puts "\n📊 TRAINING DATA VERIFICATION WITH CONTEXT"
    puts "="*80
    puts "Total examples: #{total_examples}"
    puts "Total templates: #{total_templates}"
    puts "Processing by template for consistent context..."
    puts "="*80

    # Process limits
    max_templates = 2  # Start with 50 templates for testing
    examples_per_batch = 25  # Examples to verify per API call

    puts "\nProcessing first #{max_templates} templates..."
    puts "Estimated API calls: ~#{max_templates * 2}" # Roughly 2 calls per template (pos + neg)
    puts "\nPress Enter to continue or Ctrl+C to cancel..."
    STDIN.gets

    verified_count = 0
    rejected_count = 0
    error_count = 0
    templates_processed = 0

    # Process templates one by one
    Template.limit(max_templates).each do |template|
      templates_processed += 1

      # Get examples for this template's signal category
      signal_category = template.signal_category

      # Process positive examples
      ["Positive", "Negative"].each do |polarity|
        label = "#{signal_category.gsub(' ', '_')}_#{polarity}"
        examples = Example.where(label: label, verified: nil).limit(examples_per_batch)

        next if examples.empty?

        puts "\n[Template #{templates_processed}/#{max_templates}] #{template.signal} (#{polarity})"
        puts "  Verifying #{examples.count} examples..."

        # Verify this batch with full context
        results = verify_batch_with_template_context(
          examples,
          template,
          polarity,
          CLAUDE_API_KEY
        )

        if results.nil?
          error_count += examples.count
          puts "  ❌ API error"
          next
        end

        # Update database with results
        examples.each_with_index do |example, idx|
          if results[idx]
            verdict = results[idx]['verdict']

            if verdict == 'CORRECT'
              example.update!(verified: true)
              verified_count += 1
              print "✓"
            elsif verdict == 'INCORRECT'
              example.update!(verified: false)
              rejected_count += 1
              print "✗"
            else
              # UNCERTAIN - leave as nil
              print "?"
            end
          end
        end

        # Rate limiting
        sleep 1
      end
    end

    puts "\n\n" + "="*80
    puts "VERIFICATION COMPLETE"
    puts "="*80
    puts "Templates processed: #{templates_processed}"
    puts "Examples verified (accurate): #{verified_count}"
    puts "Examples rejected (inaccurate): #{rejected_count}"
    puts "Errors/skipped: #{error_count}"

    show_summary
  end

  desc "Show verification summary with problem categories"
  task verification_summary: :environment do
    show_summary
  end

  desc "Export only verified examples to new training file"
  task export_verified: :environment do
    output_file = Rails.root.join("training_data_verified.txt")

    puts "Exporting verified examples to #{output_file}..."

    File.open(output_file, 'w') do |f|
      Example.where(verified: true).find_each do |example|
        f.puts example.message
      end
    end

    verified_count = Example.where(verified: true).count
    puts "✅ Exported #{verified_count} verified examples"
  end

  desc "Clear all verifications and start fresh"
  task clear_verifications: :environment do
    puts "Clearing all verification flags..."
    Example.update_all(verified: nil)
    puts "✅ All examples marked as unverified"
  end

  private

  def verify_batch_with_template_context(examples, template, polarity, api_key)
    # Build verification prompt with full context
    prompt = build_contextual_verification_prompt(examples, template, polarity)

    uri = URI('https://api.anthropic.com/v1/messages')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = api_key
    request['anthropic-version'] = '2023-06-01'

    request.body = {
      model: 'claude-opus-4-1-20250805',
      max_tokens: 1500,
      temperature: 0.1,  # Low temperature for consistency
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
        puts "  ❌ API Error: #{result['error']['message']}"
        return nil
      end

      # Parse JSON response
      content = result.dig('content', 0, 'text')

      # Extract JSON from response
      json_match = content.match(/\[.*\]/m)
      if json_match
        return JSON.parse(json_match[0])
      else
        puts "  ❌ Could not parse response"
        return nil
      end

    rescue => e
      puts "  ❌ Error: #{e.message}"
      nil
    end
  end

  def build_contextual_verification_prompt(examples, template, polarity)
    # Get the relevant description
    description = polarity == "Positive" ? template.positive_description : template.negative_description
    indicator = polarity == "Positive" ? template.positive_indicator : template.negative_indicator

    # Get contrasting description to help Claude understand the difference
    opposite_polarity = polarity == "Positive" ? "Negative" : "Positive"
    opposite_description = polarity == "Positive" ? template.negative_description : template.positive_description

    prompt = <<~PROMPT
      You are validating training data for a workplace culture classifier.

      SIGNAL CONTEXT:
      - Parent Metric: #{template.metric}
      - Sub-metric: #{template.sub_metric}
      - Signal Category: #{template.signal_category}
      - Specific Signal: #{template.signal}
      - Polarity: #{polarity}

      WHAT THIS SIGNAL (#{polarity}) MEANS:
      #{description}

      WHAT THE OPPOSITE (#{opposite_polarity}) WOULD LOOK LIKE:
      #{opposite_description if opposite_description}

      EXAMPLE INDICATOR FOR #{polarity.upcase}:
      #{indicator}

      KEY PRINCIPLES:
      - "#{polarity}" means this behavior #{polarity == 'Positive' ? 'IMPROVES' : 'HARMS'} workplace culture
      - The message should clearly demonstrate the signal as described above
      - Consider both direct and subtle manifestations as outlined in the descriptions
      - Use the descriptions above as the authoritative guide for what qualifies
      - If the behavior could reasonably fit the description provided, it's CORRECT
      - If it contradicts the description or represents a different signal entirely, it's INCORRECT

      EXAMPLES TO VERIFY:
      Each should be labeled as "#{template.signal_category}_#{polarity}"

    PROMPT

    examples.each_with_index do |example, idx|
      # Extract text from FastText format
      if example.message =~ /^__label__\S+\s+(.*)$/
        text = $1
        prompt += "#{idx + 1}. \"#{text}\"\n"
      end
    end

    prompt += <<~PROMPT

      Based on the descriptions above, determine if each message correctly demonstrates "#{template.signal}" with #{polarity} polarity:
      - CORRECT: The message matches the description provided for this signal
      - INCORRECT: The message doesn't match the description or shows a different signal
      - UNCERTAIN: Ambiguous or needs more context

      Respond with a JSON array:
      [{"verdict": "CORRECT|INCORRECT|UNCERTAIN", "reason": "brief explanation"}]
    PROMPT

    prompt
  end

  def show_summary
    puts "\n📈 VERIFICATION SUMMARY"
    puts "="*80

    total = Example.count
    verified = Example.where(verified: true).count
    rejected = Example.where(verified: false).count
    unverified = Example.where(verified: nil).count

    puts "Total examples: #{total}"
    puts "✅ Verified (accurate): #{verified} (#{(verified.to_f / total * 100).round(1)}%)"
    puts "❌ Rejected (inaccurate): #{rejected} (#{(rejected.to_f / total * 100).round(1)}%)"
    puts "⏳ Unverified: #{unverified} (#{(unverified.to_f / total * 100).round(1)}%)"

    # Show problem categories
    if rejected > 0
      puts "\n🔍 Most rejected labels (Top 10):"
      Example.where(verified: false)
             .group(:label)
             .count
             .sort_by { |_, count| -count }
             .first(10)
             .each do |label, count|
        total_for_label = Example.where(label: label).count
        percent = (count.to_f / total_for_label * 100).round(1)
        puts "  #{label}: #{count}/#{total_for_label} rejected (#{percent}%)"
      end
    end

    if verified > 0
      puts "\n✓ Best performing labels (Top 10):"
      Example.where(verified: true)
             .group(:label)
             .count
             .sort_by { |_, count| -count }
             .first(10)
             .each do |label, count|
        total_for_label = Example.where(label: label).count
        percent = (count.to_f / total_for_label * 100).round(1)
        puts "  #{label}: #{count}/#{total_for_label} verified (#{percent}%)"
      end
    end

    # Show by template success rate
    puts "\n📊 Verification rate by signal category:"
    Template.distinct.pluck(:signal_category).sort.each do |category|
      ["Positive", "Negative"].each do |polarity|
        label = "#{category.gsub(' ', '_')}_#{polarity}"
        verified = Example.where(label: label, verified: true).count
        rejected = Example.where(label: label, verified: false).count
        total = Example.where(label: label).count

        next if total == 0

        rate = (verified.to_f / (verified + rejected) * 100).round(1) rescue 0
        status = if rate >= 80
          "✅"
        elsif rate >= 60
          "⚠️"
        else
          "❌"
        end

        puts "  #{status} #{label}: #{rate}% accurate (#{verified}/#{verified + rejected} verified)"
      end
    end
  end
end
