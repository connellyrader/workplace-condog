# lib/tasks/claude.rake
require 'net/http'
require 'json'
require 'securerandom'

namespace :claude do
  desc "Generate training examples using Claude API (minimal validation)"
  task generate: :environment do
    # Configuration
    api_key = ENV['ANTHROPIC_API_KEY']
    examples_to_generate = 10 # per polarity per template
    delay_between_requests = 1.0
    use_basic_validation = true # Just length and obvious errors

    raise "ANTHROPIC_API_KEY not set" unless api_key

    # Statistics tracking
    stats = {
      generated: 0,
      saved: 0,
      rejected: 0,
      templates_processed: 0
    }

    # Get templates that need more examples
    templates_needing_examples = Template.left_joins(:examples)
      .group('templates.id')
      .having('COUNT(examples.id) < ?', examples_to_generate * 2)
      .order('COUNT(examples.id) ASC, templates.id DESC')

    puts "=" * 60
    puts "CLAUDE TRAINING DATA GENERATION"
    puts "=" * 60
    puts "Templates needing examples: #{templates_needing_examples.count}"
    puts "Examples to generate per polarity: #{examples_to_generate}"
    puts "Basic validation: #{use_basic_validation ? 'Enabled' : 'Disabled'}"
    puts "=" * 60

    # Process templates
    templates_to_process = templates_needing_examples.limit(50)

    templates_to_process.find_each.with_index do |template, index|
      puts "\n[#{index + 1}/#{templates_to_process.count}] Processing: #{template.signal}"
      stats[:templates_processed] += 1

      begin
        # Check existing examples
        positive_count = template.examples.where("message LIKE '%_Positive %'").count
        negative_count = template.examples.where("message LIKE '%_Negative %'").count

        # Generate positive examples if needed
        if positive_count < examples_to_generate
          puts "  Generating #{examples_to_generate} positive examples..."

          examples = generate_examples(api_key, template, 'positive', examples_to_generate)
          stats[:generated] += examples.length

          # Minimal validation then save all
          saved = if use_basic_validation
            save_with_basic_validation(template, examples, 'Positive', stats)
          else
            save_examples_directly(template, examples, 'Positive')
          end

          stats[:saved] += saved
          puts "    Generated: #{examples.length}, Saved: #{saved}"
        end

        sleep(delay_between_requests)

        # Generate negative examples if needed
        if negative_count < examples_to_generate
          puts "  Generating #{examples_to_generate} negative examples..."

          examples = generate_examples(api_key, template, 'negative', examples_to_generate)
          stats[:generated] += examples.length

          saved = if use_basic_validation
            save_with_basic_validation(template, examples, 'Negative', stats)
          else
            save_examples_directly(template, examples, 'Negative')
          end

          stats[:saved] += saved
          puts "    Generated: #{examples.length}, Saved: #{saved}"
        end

        sleep(delay_between_requests)

      rescue => e
        puts "  ERROR: #{e.message}"
        Rails.logger.error "Failed for #{template.signal}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      end
    end

    # Print final statistics
    print_generation_stats(stats)
    check_label_balance
  end

  desc "Export training data to FastText format"
  task export: :environment do
    timestamp = Time.current.strftime('%Y%m%d_%H%M%S')
    filename = "training_data_#{timestamp}.txt"

    File.open(filename, 'w') do |file|
      Example.find_each do |example|
        file.puts example.message
      end
    end

    puts "Exported #{Example.count} examples to #{filename}"
  end

  desc "Export only high-quality validated examples"
  task export_validated: :environment do
    timestamp = Time.current.strftime('%Y%m%d_%H%M%S')
    filename = "training_data_validated_#{timestamp}.txt"

    # If you have a validation_confidence column
    examples = if Example.column_names.include?('validation_confidence')
      Example.where('validation_confidence > ?', 0.7).or(Example.where(validation_confidence: nil))
    else
      Example.all
    end

    File.open(filename, 'w') do |file|
      examples.find_each do |example|
        file.puts example.message
      end
    end

    puts "Exported #{examples.count} validated examples to #{filename}"
  end

  desc "Show training data statistics"
  task stats: :environment do
    puts "\n" + "=" * 60
    puts "TRAINING DATA STATISTICS"
    puts "=" * 60

    puts "Total examples: #{Example.count}"
    puts "Total templates: #{Template.count}"

    # Examples by polarity
    positive_count = Example.where("message LIKE '%_Positive %'").count
    negative_count = Example.where("message LIKE '%_Negative %'").count

    puts "\nPolarity distribution:"
    puts "  Positive: #{positive_count}"
    puts "  Negative: #{negative_count}"
    puts "  Ratio: #{(positive_count.to_f / negative_count).round(2)}:1" if negative_count > 0

    # Check which templates need more examples
    templates_complete = Template.joins(:examples)
      .group('templates.id')
      .having('COUNT(examples.id) >= ?', 10)
      .count.keys.count

    templates_incomplete = Template.count - templates_complete

    puts "\nTemplate coverage:"
    puts "  Complete (10+ examples): #{templates_complete}"
    puts "  Incomplete: #{templates_incomplete}"

    check_label_balance
  end

  desc "Rebalance training data to fix over/under representation"
  task rebalance: :environment do
    min_examples = 50
    max_examples = 150

    puts "\n" + "=" * 60
    puts "REBALANCING TRAINING DATA"
    puts "=" * 60
    puts "Target range: #{min_examples}-#{max_examples} examples per label"

    # Get label distribution
    label_pattern = /__label__(\S+)/
    label_counts = {}

    Example.find_each do |example|
      if match = example.message.match(label_pattern)
        label = match[1]
        label_counts[label] ||= 0
        label_counts[label] += 1
      end
    end

    # Identify problems
    underrepresented = label_counts.select { |_, count| count < min_examples }
    overrepresented = label_counts.select { |_, count| count > max_examples }

    if underrepresented.any?
      puts "\nUnderrepresented labels (< #{min_examples}):"
      underrepresented.sort_by { |_, count| count }.each do |label, count|
        puts "  #{label}: #{count} examples (needs #{min_examples - count} more)"
      end
    end

    if overrepresented.any?
      puts "\nOverrepresented labels (> #{max_examples}):"
      overrepresented.sort_by { |_, count| -count }.each do |label, count|
        puts "  #{label}: #{count} examples (remove #{count - max_examples})"

        # Remove excess examples
        excess = count - max_examples
        examples_to_remove = Example.where("message LIKE ?", "%__label__#{label} %")
          .order('RANDOM()')
          .limit(excess)

        examples_to_remove.destroy_all
        puts "    → Removed #{excess} examples"
      end
    end

    if underrepresented.empty? && overrepresented.empty?
      puts "\n✅ Data is already balanced!"
    else
      puts "\n✅ Rebalancing complete!"
    end
  end

  desc "Clean duplicate examples"
  task dedupe: :environment do
    puts "Removing duplicate examples..."

    # Find duplicates based on message content (ignoring label)
    duplicates = Example.select('MIN(id) as id, COUNT(*) as count')
      .group("SUBSTR(message, INSTR(message, ' ') + 1)") # Group by text after label
      .having('COUNT(*) > 1')

    total_dupes = duplicates.sum(&:count) - duplicates.count

    if total_dupes > 0
      # Keep only the first instance of each duplicate
      duplicate_ids = []
      duplicates.each do |group|
        text_part = Example.find(group.id).message.split(' ', 2).last
        all_with_text = Example.where("message LIKE ?", "%#{text_part}")
        duplicate_ids += all_with_text.offset(1).pluck(:id) # Skip first, take rest
      end

      Example.where(id: duplicate_ids).destroy_all
      puts "Removed #{duplicate_ids.count} duplicate examples"
    else
      puts "No duplicates found!"
    end
  end

  private

  def generate_examples(api_key, template, polarity, count)
    prompt = build_prompt(template, polarity, count)
    response = call_claude_api(api_key, prompt)
    parse_examples(response)
  end

  def build_prompt(template, polarity, count)
    # Use the detailed descriptions from the database
    description = polarity == 'positive' ? template.positive_description : template.negative_description
    indicator = polarity == 'positive' ? template.positive_indicator : template.negative_indicator

    <<~PROMPT
      Generate #{count} realistic Slack-style workplace messages that exemplify this culture signal:

      Signal: #{template.signal}
      Category: #{template.signal_category}
      Metric: #{template.metric} > #{template.sub_metric}

      KEY INDICATOR: #{indicator}

      DETAILED DESCRIPTION OF WHAT TO GENERATE:
      #{description}

      You are generating #{polarity.upcase} examples that demonstrate the above description.
      Each message should clearly show the behaviors, language patterns, and situations described above.

      Requirements:
      - Messages must be authentic workplace Slack communication
      - Vary length from 5-30 words
      - Include casual language, typos, abbreviations, emojis when appropriate
      - Each example MUST specifically demonstrate the behaviors from the description above
      - Keep messages realistic but clearly matching the description
      - No generic messages - each must be specific to this exact signal and description
      - Messages should sound like real people in real workplace situations

      Format: Number each example (1., 2., 3., etc.)

      Generate exactly #{count} examples:
    PROMPT
  end

  def call_claude_api(api_key, prompt)
    uri = URI('https://api.anthropic.com/v1/messages')

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = api_key
    request['anthropic-version'] = '2023-06-01'

    request.body = {
      model: "claude-opus-4-1-20250805",
      max_tokens: 1500,
      temperature: 0.7,
      messages: [
        {
          role: "user",
          content: prompt
        }
      ]
    }.to_json

    response = http.request(request)

    unless response.code == '200'
      error_body = JSON.parse(response.body) rescue response.body
      raise "API Error #{response.code}: #{error_body}"
    end

    JSON.parse(response.body)
  end

  def parse_examples(response)
    content = response.dig('content', 0, 'text') || ''

    # Try numbered format first (1. example, 2. example, etc.)
    examples = content.scan(/^\d+[\.\)]\s*(.+?)(?=^\d+[\.\)]|\z)/m)
      .flatten
      .map { |ex| ex.strip.gsub(/\s+/, ' ') }
      .reject(&:blank?)

    # Fallback to line-by-line if numbered format fails
    if examples.empty?
      examples = content.split("\n")
        .map(&:strip)
        .reject(&:blank?)
        .reject { |line| line.match?(/^(examples?|positive|negative):/i) }
        .reject { |line| line.match?(/^\d+[\.\)]?\s*$/) } # Skip lone numbers
    end

    examples
  end

  def save_with_basic_validation(template, examples, polarity, stats)
    validated = []

    examples.each do |text|
      # Very basic validation - just prevent obvious errors
      if text.present? && text.length >= 5 && text.length <= 300
        validated << text
      else
        stats[:rejected] += 1
      end
    end

    save_examples_directly(template, validated, polarity)
    validated.length
  end

  def save_all_validated_examples(template, examples, polarity, stats)
    validated = []

    examples.each do |text|
      if validate_example(text, template, polarity)
        validated << text
      else
        stats[:rejected] += 1
      end
    end

    # Save ALL validated examples, not just a limited number
    save_examples_directly(template, validated, polarity)
    validated.length
  end

  def save_validated_examples(template, examples, polarity, max_count, stats)
    validated = []

    examples.each do |text|
      if validate_example(text, template, polarity)
        validated << text
      else
        stats[:rejected] += 1
      end

      break if validated.length >= max_count
    end

    save_examples_directly(template, validated, polarity)
    validated.length
  end

  def validate_example(text, template, polarity)
    return false if text.blank?
    return false if text.length < 10 || text.length > 300

    text_lower = text.downcase

    # Basic polarity check
    if polarity == 'Positive'
      # Reject if contains strongly negative sentiment
      strong_negative = ['hate', 'terrible', 'awful', 'horrible', 'quit', 'failed',
                        'angry', 'furious', 'disgusted', 'worst']
      return false if strong_negative.any? { |word| text_lower.include?(word) }
    else
      # Reject if contains strongly positive sentiment for negative examples
      strong_positive = ['amazing', 'excellent', 'fantastic', 'wonderful', 'love',
                        'perfect', 'brilliant', 'awesome', 'best']
      return false if strong_positive.any? { |word| text_lower.include?(word) }
    end

    # Category-specific validation
    category = template.signal_category.downcase

    # Check for minimum relevance to category
    category_keywords = {
      'recognition' => ['thanks', 'appreciate', 'great job', 'well done', 'kudos'],
      'burnout' => ['tired', 'exhausted', 'overwhelmed', 'stress', 'burnt out'],
      'collaboration' => ['together', 'team', 'sync', 'collaborate', 'meeting'],
      'belonging' => ['welcome', 'included', 'team', 'us', 'together'],
      'support' => ['help', 'support', 'assist', 'here for', 'got your back'],
      'conflict' => ['disagree', 'issue', 'problem', 'concern', 'tension'],
      'growth' => ['learn', 'develop', 'improve', 'progress', 'skill']
    }

    # For known categories, check for at least one relevant keyword
    if keywords = category_keywords[category]
      return keywords.any? { |kw| text_lower.include?(kw) }
    end

    true # Accept if no specific rules apply
  end

  def save_examples_directly(template, examples, polarity)
    signal_category = template.signal_category.gsub(' ', '_')
    full_label = "#{signal_category}_#{polarity}"

    examples.each do |text|
      Example.create!(
        template: template,
        label: full_label,
        message: "__label__#{full_label} #{text}"
      )
    end

    examples.length
  end

  def print_generation_stats(stats)
    puts "\n" + "=" * 60
    puts "GENERATION COMPLETE"
    puts "=" * 60
    puts "Templates processed: #{stats[:templates_processed]}"
    puts "Examples generated: #{stats[:generated]}"
    puts "Examples saved: #{stats[:saved]}"
    puts "Examples rejected: #{stats[:rejected]}"

    if stats[:generated] > 0
      acceptance_rate = (stats[:saved].to_f / stats[:generated] * 100).round(1)
      puts "Acceptance rate: #{acceptance_rate}%"
    end
  end

  def check_label_balance
    puts "\n" + "=" * 60
    puts "LABEL BALANCE CHECK"
    puts "=" * 60

    # Count by extracting labels from messages
    label_counts = {}
    Example.find_in_batches(batch_size: 1000) do |batch|
      batch.each do |example|
        if match = example.message.match(/__label__(\S+)/)
          label = match[1]
          label_counts[label] ||= 0
          label_counts[label] += 1
        end
      end
    end

    if label_counts.empty?
      puts "No labeled examples found"
      return
    end

    # Calculate statistics
    counts = label_counts.values
    avg = counts.sum.to_f / counts.length
    min_count = counts.min
    max_count = counts.max

    puts "Total unique labels: #{label_counts.length}"
    puts "Total examples: #{counts.sum}"
    puts "Average per label: #{avg.round(1)}"
    puts "Min examples: #{min_count}"
    puts "Max examples: #{max_count}"

    if min_count > 0
      puts "Imbalance ratio: #{(max_count.to_f / min_count).round(2)}:1"
    end

    # Show extremes
    sorted_labels = label_counts.sort_by { |_, count| -count }

    puts "\nMost common labels:"
    sorted_labels.first(5).each do |label, count|
      puts "  #{label}: #{count}"
    end

    puts "\nLeast common labels:"
    sorted_labels.last(5).reverse.each do |label, count|
      puts "  #{label}: #{count}"
    end

    # Recommendations
    if min_count == 0 || (max_count.to_f / min_count > 5)
      puts "\n⚠️  WARNING: Severe imbalance detected"
      puts "   Run: rake claude:rebalance"
    elsif max_count.to_f / min_count > 3
      puts "\n⚠️  CAUTION: Moderate imbalance detected"
      puts "   Consider running: rake claude:rebalance"
    else
      puts "\n✅ Label balance is acceptable"
    end
  end
end
