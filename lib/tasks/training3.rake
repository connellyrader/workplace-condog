# lib/tasks/training_batch.rake
require 'net/http'
require 'json'

namespace :training3 do
  desc "Generate training data for all categories that need it"
  task generate_all: :environment do

    CLAUDE_API_KEY = ENV['ANTHROPIC_API_KEY']

    if CLAUDE_API_KEY.blank?
      puts "❌ Please set ANTHROPIC_API_KEY environment variable"
      exit
    end

    # Parallel processing configuration
    worker_id = (ENV['WORKER_ID'] || '1').to_i
    num_workers = (ENV['NUM_WORKERS'] || '1').to_i

    # Get all unique signal categories
    all_categories = Template.distinct.pluck(:signal_category).sort

    puts "\n📊 TRAINING DATA GENERATION - WORKER #{worker_id}/#{num_workers}"
    puts "="*80
    puts "Total signal categories: #{all_categories.count}"
    puts "Worker #{worker_id} processing every #{num_workers}th category starting at position #{worker_id}"
    puts "="*80

    # Track statistics
    total_generated = 0
    total_saved = 0
    skipped_categories = []
    failed_categories = []
    processed_categories = []

    # Process each category
    all_categories.each_with_index do |signal_category, idx|
      # Skip if not assigned to this worker (modulo division for distribution)
      next unless idx % num_workers == worker_id - 1

      puts "\n[Worker #{worker_id}][#{idx + 1}/#{all_categories.count}] Checking: #{signal_category}"

      # Get templates for this category
      templates = Template.where(signal_category: signal_category)

      # Check if ALL templates have descriptions
      templates_with_desc = templates.where.not(positive_description: nil)
                                     .where.not(negative_description: nil)

      if templates_with_desc.count != templates.count
        puts "  ⏭️  [Worker #{worker_id}] Skipping - missing descriptions (#{templates_with_desc.count}/#{templates.count} complete)"
        skipped_categories << signal_category
        next
      end

      # Check if examples already exist (use examples_needed as target)
      examples_needed = 150  # Target examples per polarity
      label_positive = "#{signal_category.gsub(' ', '_')}_Positive"
      label_negative = "#{signal_category.gsub(' ', '_')}_Negative"

      existing_positive = Example.where(label: label_positive).count
      existing_negative = Example.where(label: label_negative).count

      if existing_positive >= examples_needed && existing_negative >= examples_needed
        puts "  ✅ [Worker #{worker_id}] Already has enough examples (Pos: #{existing_positive}, Neg: #{existing_negative}) - skipping"
        skipped_categories << signal_category
        next
      end

      puts "  📝 [Worker #{worker_id}] Generating examples (currently Pos: #{existing_positive}, Neg: #{existing_negative})"
      puts "  Templates: #{templates.count}"

      # Generate for both polarities if needed
      examples_needed = 150  # Target per polarity
      ["Positive", "Negative"].each do |polarity|
        label = "#{signal_category.gsub(' ', '_')}_#{polarity}"
        existing = Example.where(label: label).count

        if existing >= examples_needed
          puts "    ✓ #{polarity} already has #{existing} examples - skipping"
          next
        end

        # Calculate how many more we need
        examples_to_generate = examples_needed - existing

        puts "    → [Worker #{worker_id}] Generating #{examples_to_generate} more #{polarity} examples (currently has #{existing})..."

        # Build prompt with the right number of examples
        prompt = build_batch_prompt_with_count(signal_category, templates, polarity, examples_to_generate)

        # Generate examples
        examples = generate_batch_examples(prompt, CLAUDE_API_KEY)

        if examples.nil? || examples.empty?
          puts "      ❌ [Worker #{worker_id}] Failed to generate examples"
          failed_categories << "#{signal_category} (#{polarity}) - Worker #{worker_id}"
          next
        end

        puts "      ✅ Generated #{examples.count} examples"

        # Save to database
        saved = save_examples_batch(signal_category, polarity, examples, templates)

        puts "      💾 Saved #{saved} to database"

        total_generated += examples.count
        total_saved += saved

        # Rate limiting
        sleep 2
      end

      processed_categories << signal_category
    end

    # Final summary
    puts "\n" + "="*80
    puts "📊 WORKER #{worker_id} GENERATION COMPLETE"
    puts "="*80
    puts "Categories processed by this worker: #{processed_categories.count}"
    puts "Categories skipped by this worker: #{skipped_categories.count}"
    puts "Total examples generated: #{total_generated}"
    puts "Total examples saved: #{total_saved}"

    if failed_categories.any?
      puts "\n⚠️  Failed generations (#{failed_categories.count}):"
      failed_categories.each { |cat| puts "  - #{cat}" }
    end

    # Show current database state
    puts "\n📈 Database Summary:"
    total_in_db = Example.count
    categories_with_examples = all_categories.count do |cat|
      label = "#{cat.gsub(' ', '_')}_Positive"
      Example.where(label: label).count >= 30
    end

    puts "Total examples in database: #{total_in_db}"
    puts "Categories with sufficient examples: #{categories_with_examples}/#{all_categories.count}"
  end

  private

  def build_batch_prompt_with_count(signal_category, templates, polarity, count)
    # Get the relevant descriptions
    descriptions = templates.map do |t|
      desc = polarity == "Positive" ? t.positive_description : t.negative_description
      next if desc.blank?
      "#{t.signal}:\n#{desc}"
    end.compact

    # Get indicators for additional context
    indicators = templates.map do |t|
      polarity == "Positive" ? t.positive_indicator : t.negative_indicator
    end.compact.uniq

    prompt = <<~PROMPT
      Generate #{count} workplace Slack/Teams messages for "#{signal_category}" with #{polarity} polarity.

      DETAILED SIGNAL DESCRIPTIONS:
      #{descriptions.join("\n\n")}

      EXAMPLE INDICATORS:
      #{indicators.first(5).map { |i| "• #{i}" }.join("\n")}

      KEY REQUIREMENTS:
      1. Each message must clearly match ONE of the descriptions above
      2. Messages must show #{polarity} impact on workplace culture
      3. Be unambiguous - obviously #{polarity.downcase}, not neutral
      4. Natural Slack/Teams language (5-40 words)
      5. Mix examples across ALL signal types listed
      6. Include variety: questions, statements, responses, updates

      CULTURAL IMPACT:
      - Positive = Improves/supports healthy workplace culture
      - Negative = Harms/degrades workplace culture

      Generate exactly #{count} messages, one per line, no numbering:
    PROMPT

    prompt
  end

  def build_batch_prompt(signal_category, templates, polarity)
    # Get the relevant descriptions
    descriptions = templates.map do |t|
      desc = polarity == "Positive" ? t.positive_description : t.negative_description
      next if desc.blank?
      "#{t.signal}:\n#{desc}"
    end.compact

    # Get indicators for additional context
    indicators = templates.map do |t|
      polarity == "Positive" ? t.positive_indicator : t.negative_indicator
    end.compact.uniq

    # Generate 150 examples per polarity for better model training
    examples_needed = 150

    prompt = <<~PROMPT
      Generate #{examples_needed} workplace Slack/Teams messages for "#{signal_category}" with #{polarity} polarity.

      DETAILED SIGNAL DESCRIPTIONS:
      #{descriptions.join("\n\n")}

      EXAMPLE INDICATORS:
      #{indicators.first(5).map { |i| "• #{i}" }.join("\n")}

      KEY REQUIREMENTS:
      1. Each message must clearly match ONE of the descriptions above
      2. Messages must show #{polarity} impact on workplace culture
      3. Be unambiguous - obviously #{polarity.downcase}, not neutral
      4. Natural Slack/Teams language (5-40 words)
      5. Mix examples across ALL signal types listed
      6. Include variety: questions, statements, responses, updates

      CULTURAL IMPACT:
      - Positive = Improves/supports healthy workplace culture
      - Negative = Harms/degrades workplace culture

      Generate exactly #{examples_needed} messages, one per line, no numbering:
    PROMPT

    prompt
  end

  def generate_batch_examples(prompt, api_key)
    uri = URI('https://api.anthropic.com/v1/messages')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 360  # Increased to 180 seconds for 75 examples
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = api_key
    request['anthropic-version'] = '2023-06-01'

    request.body = {
      model: 'claude-opus-4-1-20250805',  # Using Opus for highest quality
      max_tokens: 2000,
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
        puts "      ❌ API Error: #{result['error']['message']}"
        return nil
      end

      content = result.dig('content', 0, 'text')
      return nil unless content

      # Clean and return as array
      content.lines.map(&:strip).reject(&:blank?).reject { |l| l =~ /^\d+\./ }
    rescue => e
      puts "      ❌ Error calling API: #{e.message}"
      nil
    end
  end

  def save_examples_batch(signal_category, polarity, examples, templates)
    saved_count = 0

    # Format signal category for label (replace spaces with underscores)
    label_formatted = "#{signal_category.gsub(' ', '_')}_#{polarity}"

    examples.each do |example_text|
      begin
        # Create FastText formatted message
        fasttext_message = "__label__#{label_formatted} #{example_text}"

        # Save with the first template as reference
        Example.create!(
          template_id: templates.first.id,
          label: label_formatted,  # e.g., "Support_Resources_Positive"
          message: fasttext_message  # Full FastText format
        )

        saved_count += 1
      rescue => e
        puts "      ⚠️  Error saving example: #{e.message}"
      end
    end

    saved_count
  end
end

# Helper task to show progress
namespace :training3 do
  desc "Show training data generation progress"
  task progress: :environment do
    all_categories = Template.distinct.pluck(:signal_category).sort

    puts "\n📊 TRAINING DATA PROGRESS"
    puts "="*80

    categories_ready = 0
    categories_with_examples = 0

    all_categories.each_with_index do |category, idx|
      templates = Template.where(signal_category: category)

      # Check descriptions
      templates_with_desc = templates.where.not(positive_description: nil)
                                     .where.not(negative_description: nil)
      has_descriptions = templates_with_desc.count == templates.count

      # Count existing examples
      label_positive = "#{category.gsub(' ', '_')}_Positive"
      label_negative = "#{category.gsub(' ', '_')}_Negative"

      positive_count = Example.where(label: label_positive).count
      negative_count = Example.where(label: label_negative).count

      status = if positive_count >= 30 && negative_count >= 30
        categories_with_examples += 1
        "✅"
      elsif positive_count > 0 || negative_count > 0
        "⚠️"
      elsif has_descriptions
        categories_ready += 1
        "📝"  # Ready to generate
      else
        "❌"  # Missing descriptions
      end

      puts "#{(idx + 1).to_s.rjust(3)}. #{status} #{category.ljust(35)} " \
           "Pos: #{positive_count.to_s.rjust(3)} | " \
           "Neg: #{negative_count.to_s.rjust(3)} | " \
           "Desc: #{has_descriptions ? 'Yes' : 'No'}"
    end

    total_examples = Example.count

    puts "\n📈 SUMMARY"
    puts "="*80
    puts "Total examples in database: #{total_examples}"
    puts "Categories with examples: #{categories_with_examples}/#{all_categories.count}"
    puts "Categories ready to generate: #{categories_ready}"
    puts "\nLegend:"
    puts "  ✅ = Has 30+ examples for both polarities"
    puts "  ⚠️ = Has some examples but needs more"
    puts "  📝 = Has descriptions, ready to generate"
    puts "  ❌ = Missing descriptions, can't generate"
  end
end
