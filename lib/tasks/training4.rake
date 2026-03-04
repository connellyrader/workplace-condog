# lib/tasks/training4.rake
require 'net/http'
require 'json'

namespace :training4 do
  # ================== CONFIGURATION ==================
  TEMPLATES_TO_PROCESS = ENV['TEMPLATES_TO_PROCESS']&.to_i || 1228
  TARGET_EXAMPLES_PER_CATEGORY = ENV['TARGET_PER_CATEGORY']&.to_i || 300  # Changed to 150 to balance
  TARGET_PER_POLARITY = TARGET_EXAMPLES_PER_CATEGORY / 2  # 75 positive, 75 negative
  MAX_PER_API_CALL = 10
  API_DELAY_SECONDS = 1.0
  HTTP_TIMEOUT = 180
  TEMPERATURE = 0.6
  VALIDATION_BATCH_SIZE = 15

  # Parallel processing configuration
  TOTAL_WORKERS = ENV['TOTAL_WORKERS']&.to_i || 1
  WORKER_ID = ENV['WORKER_ID']&.to_i || 1

  # Length distribution
  LENGTH_DISTRIBUTION = {
    short: { range: "5-15 words", target_ratio: 3 },
    medium: { range: "16-40 words", target_ratio: 5 },
    long: { range: "41-80 words", target_ratio: 2 }
  }

  # Style distribution
  STYLE_DISTRIBUTION = {
    professional: {
      description: "Professional workplace language, proper grammar, no slang",
      target_ratio: 4
    },
    casual: {
      description: "Conversational tone, relaxed but workplace appropriate",
      target_ratio: 4
    },
    informal: {
      description: "Very casual, includes slang (lol, wtf, smh, omg), typos, abbreviations, emojis",
      target_ratio: 2
    }
  }

  # ================== MAIN GENERATION (BALANCED) ==================

  desc "Generate balanced training data - prioritizes categories with fewer examples"
  task generate: :environment do
    api_key = ENV['ANTHROPIC_API_KEY']
    raise "ANTHROPIC_API_KEY not set" unless api_key

    if WORKER_ID > TOTAL_WORKERS || WORKER_ID < 1
      raise "Invalid WORKER_ID: #{WORKER_ID}. Must be between 1 and #{TOTAL_WORKERS}"
    end

    puts "=" * 80
    puts "TRAINING4: BALANCED GENERATION SYSTEM"
    puts "Worker #{WORKER_ID} of #{TOTAL_WORKERS}"
    puts "Target per category: #{TARGET_EXAMPLES_PER_CATEGORY} (#{TARGET_PER_POLARITY} per polarity)"
    puts "=" * 80

    # Find categories that need balancing, sorted by gap (smallest first)
    categories_needing_work = find_categories_by_gap

    if categories_needing_work.empty?
      puts "✅ All categories are at target!"
      return
    end

    # Divide work among workers
    categories_for_worker = divide_categories_among_workers(categories_needing_work)

    if categories_for_worker.empty?
      puts "✅ No categories assigned to Worker #{WORKER_ID}!"
      return
    end

    puts "\nWorker #{WORKER_ID} assigned #{categories_for_worker.length} categories"
    puts "\nCategories to process (ordered by need):"
    categories_for_worker.first(10).each do |cat_info|
      puts "  - #{cat_info[:category]}: #{cat_info[:current_count]} → #{TARGET_EXAMPLES_PER_CATEGORY} (need #{cat_info[:gap]})"
    end
    puts "  ... and #{categories_for_worker.length - 10} more" if categories_for_worker.length > 10

    # Process each category
    total_generated = 0
    total_saved = 0

    categories_for_worker.each_with_index do |cat_info, idx|
      category = cat_info[:category]

      puts "\n[#{idx + 1}/#{categories_for_worker.length}] Processing: #{category}"
      puts "  Current: #{cat_info[:current_count]} | Target: #{TARGET_EXAMPLES_PER_CATEGORY} | Gap: #{cat_info[:gap]}"

      # Get a template for this category
      template = Template.find_by(signal_category: category)
      unless template
        puts "  ⚠️  No template found for #{category}, skipping"
        next
      end

      # Generate for both polarities to reach target
      [:positive, :negative].each do |polarity|
        label = "#{category.gsub(' ', '_')}_#{polarity.to_s.capitalize}"
        current = Example.where(verified: true, label: label).count
        needed = TARGET_PER_POLARITY - current

        if needed > 0
          puts "  #{polarity.to_s.capitalize}: Need #{needed} more examples"

          generated, saved = generate_examples_for_template(
            template,
            polarity.to_s,
            needed,
            api_key
          )

          total_generated += generated
          total_saved += saved
          puts "    → Generated: #{generated}, Saved: #{saved}"
        else
          puts "  #{polarity.to_s.capitalize}: ✓ Already at target (#{current})"
        end
      end
    end

    puts "\n" + "=" * 80
    puts "WORKER #{WORKER_ID} COMPLETE"
    puts "=" * 80
    puts "Total generated: #{total_generated}"
    puts "Total saved: #{total_saved}"
    puts "Success rate: #{(total_saved.to_f / total_generated * 100).round(1)}%" if total_generated > 0
    puts "\nRun 'rake training4:validate' to validate the generated examples"
  end

  # ================== STATUS REPORT ==================

  desc "Show current balance status across all categories"
  task status: :environment do
    puts "=" * 80
    puts "TRAINING DATA BALANCE STATUS"
    puts "=" * 80

    categories = get_all_category_stats

    total_examples = categories.sum { |c| c[:verified_count] }
    avg_per_category = total_examples.to_f / categories.length

    puts "\nOverall Statistics:"
    puts "  Total categories: #{categories.length}"
    puts "  Total verified examples: #{total_examples}"
    puts "  Average per category: #{avg_per_category.round(1)}"
    puts "  Target per category: #{TARGET_EXAMPLES_PER_CATEGORY}"
    puts "  Min: #{categories.min_by { |c| c[:verified_count] }[:verified_count]}"
    puts "  Max: #{categories.max_by { |c| c[:verified_count] }[:verified_count]}"

    below_target = categories.select { |c| c[:verified_count] < TARGET_EXAMPLES_PER_CATEGORY }
    puts "\nCategories below target (#{TARGET_EXAMPLES_PER_CATEGORY}): #{below_target.length}"

    total_gap = below_target.sum { |c| TARGET_EXAMPLES_PER_CATEGORY - c[:verified_count] }
    puts "Total examples needed: #{total_gap}"

    puts "\nBottom 20 categories (most need):"
    categories.sort_by { |c| c[:verified_count] }.first(20).each_with_index do |cat, idx|
      gap = TARGET_EXAMPLES_PER_CATEGORY - cat[:verified_count]
      puts "  #{idx + 1}. #{cat[:category].ljust(40)} #{cat[:verified_count].to_s.rjust(3)} (need #{gap})"
    end

    puts "\nTop 10 categories (well-balanced):"
    categories.sort_by { |c| c[:verified_count] }.last(10).reverse.each_with_index do |cat, idx|
      excess = cat[:verified_count] - TARGET_EXAMPLES_PER_CATEGORY
      marker = excess > 0 ? "(#{excess} over)" : "✓"
      puts "  #{idx + 1}. #{cat[:category].ljust(40)} #{cat[:verified_count].to_s.rjust(3)} #{marker}"
    end
  end

  # ================== VALIDATION TASK ==================

  desc "Validate unverified examples and mark them as verified true/false (parallel-safe)"
  task validate: :environment do
    api_key = ENV['ANTHROPIC_API_KEY']
    raise "ANTHROPIC_API_KEY not set" unless api_key

    if WORKER_ID > TOTAL_WORKERS || WORKER_ID < 1
      raise "Invalid WORKER_ID: #{WORKER_ID}. Must be between 1 and #{TOTAL_WORKERS}"
    end

    puts "=" * 80
    puts "TRAINING4: VALIDATION SYSTEM"
    puts "Worker #{WORKER_ID} of #{TOTAL_WORKERS}"
    puts "=" * 80

    all_unverified = Example.where(verified: nil).includes(:template).to_a

    if all_unverified.empty?
      puts "✅ No unverified examples to validate!"
      return
    end

    unverified_for_worker = all_unverified.select.with_index do |example, index|
      (index % TOTAL_WORKERS) == (WORKER_ID - 1)
    end

    puts "Worker #{WORKER_ID} assigned #{unverified_for_worker.count} of #{all_unverified.count} examples"
    puts "Validation batch size: #{VALIDATION_BATCH_SIZE}"
    puts "=" * 80

    grouped = unverified_for_worker.group_by { |ex|
      polarity = ex.label.end_with?('_Positive') ? 'positive' : 'negative'
      [ex.template, polarity]
    }

    total_validated = 0
    total_rejected = 0

    grouped.each do |(template, polarity), examples|
      puts "\nValidating: #{template.signal} (#{polarity})"
      puts "  Category: #{template.signal_category}"
      puts "  Examples to validate: #{examples.count}"

      examples.each_slice(VALIDATION_BATCH_SIZE) do |batch|
        validated, rejected = validate_batch(batch, template, polarity, api_key)
        total_validated += validated
        total_rejected += rejected
      end
    end

    puts "\n" + "=" * 80
    puts "WORKER #{WORKER_ID} VALIDATION COMPLETE"
    puts "=" * 80
    puts "Total validated (kept): #{total_validated}"
    puts "Total rejected: #{total_rejected}"
    puts "Acceptance rate: #{(total_validated.to_f / (total_validated + total_rejected) * 100).round(1)}%" if (total_validated + total_rejected) > 0
  end

  private

  # ================== BALANCING HELPERS ==================

  def find_categories_by_gap
    categories = get_all_category_stats

    # Filter and sort by gap (smallest count first = biggest need)
    categories
      .select { |c| c[:verified_count] < TARGET_EXAMPLES_PER_CATEGORY }
      .sort_by { |c| c[:verified_count] }
      .map do |cat|
        {
          category: cat[:category],
          current_count: cat[:verified_count],
          gap: TARGET_EXAMPLES_PER_CATEGORY - cat[:verified_count]
        }
      end
  end

  def get_all_category_stats
    # Get all unique categories with their verified counts
    sql = <<-SQL
      SELECT
        label,
        COUNT(*) as count
      FROM examples
      WHERE verified = true
      GROUP BY label
    SQL

    results = ActiveRecord::Base.connection.execute(sql)

    category_stats = {}

    results.each do |row|
      # Extract category from label (remove _Positive or _Negative suffix)
      label = row['label']
      category = label.gsub(/_(?:Positive|Negative)$/, '').gsub('_', ' ')

      category_stats[category] ||= 0
      category_stats[category] += row['count'].to_i
    end

    category_stats.map do |category, count|
      { category: category, verified_count: count }
    end
  end

  def divide_categories_among_workers(categories)
    # Distribute categories evenly using round-robin
    categories.select.with_index do |cat, index|
      (index % TOTAL_WORKERS) == (WORKER_ID - 1)
    end
  end

  # ================== GENERATION HELPERS ==================

  def generate_examples_for_template(template, polarity, needed_count, api_key)
    label = "#{template.signal_category.gsub(' ', '_')}_#{polarity.capitalize}"
    current_count = Example.where(verified: true, label: label).count
    still_needed = TARGET_PER_POLARITY - current_count

    if still_needed <= 0
      return [0, 0]
    end

    to_generate = [needed_count, still_needed].min
    distribution = calculate_exact_distribution(to_generate)

    all_examples = []
    total_generated = 0

    distribution.each_with_index do |combo, idx|
      examples = generate_batch(
        template,
        polarity,
        combo[:length_type],
        combo[:style_type],
        combo[:count],
        api_key
      )

      all_examples.concat(examples)
      total_generated += combo[:count]

      sleep API_DELAY_SECONDS if idx < distribution.length - 1
    end

    saved = save_examples(template, all_examples, polarity)
    [total_generated, saved]
  end

  def calculate_exact_distribution(total_needed)
    distribution = []

    length_total = LENGTH_DISTRIBUTION.values.sum { |v| v[:target_ratio] }
    style_total = STYLE_DISTRIBUTION.values.sum { |v| v[:target_ratio] }

    length_counts = {}
    LENGTH_DISTRIBUTION.each do |length_type, config|
      length_counts[length_type] = (total_needed.to_f * config[:target_ratio] / length_total).round
    end

    diff = total_needed - length_counts.values.sum
    length_counts[:medium] += diff if diff != 0

    length_counts.each do |length_type, length_count|
      style_counts_for_length = {}

      STYLE_DISTRIBUTION.each do |style_type, config|
        count = (length_count.to_f * config[:target_ratio] / style_total).round
        style_counts_for_length[style_type] = count
      end

      diff = length_count - style_counts_for_length.values.sum
      style_counts_for_length[:casual] += diff if diff != 0

      style_counts_for_length.each do |style_type, count|
        next if count == 0

        remaining = count
        while remaining > 0
          batch_size = [remaining, MAX_PER_API_CALL].min
          distribution << {
            length_type: length_type,
            style_type: style_type,
            count: batch_size
          }
          remaining -= batch_size
        end
      end
    end

    distribution
  end

  def generate_batch(template, polarity, length_type, style_type, count, api_key)
    prompt = build_prompt(template, polarity, length_type, style_type, count)
    response = call_claude_api(prompt, api_key)
    examples = parse_examples(response)

    examples.map do |text|
      {
        text: text,
        length_type: length_type.to_s,
        style_type: style_type.to_s,
        generated_at: Time.current
      }
    end
  end

  def build_prompt(template, polarity, length_type, style_type, count)
    description = polarity == 'positive' ? template.positive_description : template.negative_description
    indicator = polarity == 'positive' ? template.positive_indicator : template.negative_indicator

    length_range = LENGTH_DISTRIBUTION[length_type][:range]
    style_desc = STYLE_DISTRIBUTION[style_type][:description]

    cultural_impact_explanation = if polarity == 'positive'
      <<~IMPACT
      POSITIVE CULTURAL IMPACT means behaviors that:
      - Build psychological safety (people feel safe to speak up, make mistakes, be themselves)
      - Increase transparency and trust (information is shared openly, commitments are kept)
      - Foster collaboration and inclusion (everyone contributes, diverse perspectives valued)
      - Drive engagement and energy (people are motivated, enthusiastic, committed)
      - Create clarity and alignment (clear communication, shared understanding)
      - Promote shared accountability (collective ownership, mutual support)

      Note: A message can have neutral or even serious emotional tone but still have POSITIVE cultural impact.
      Example: "We need to address this communication gap as a team" (serious tone, positive impact)
      IMPACT
    else
      <<~IMPACT
      NEGATIVE CULTURAL IMPACT means behaviors that:
      - Create psychological unsafety (fear of speaking up, walking on eggshells, hiding mistakes)
      - Increase opacity and mistrust (information hoarding, broken commitments, secrecy)
      - Foster silos and exclusion (working alone, certain voices dominate, cliques form)
      - Drive disengagement and apathy (people checked out, going through motions, minimal effort)
      - Create confusion and misalignment (unclear communication, different assumptions)
      - Promote blame and finger-pointing (individual blame, lack of support, throwing under bus)

      Note: A message can have cheerful emotional tone but still have NEGATIVE cultural impact.
      Example: "I'll just handle this myself, no worries!" (cheerful tone, negative impact - creates silo)
      IMPACT
    end

    forbidden_words = if polarity == 'positive'
      [
        "hate", "hatred", "despise", "loathe", "detest", "disgusting", "revolting", "repulsive",
        "angry", "furious", "pissed", "rage", "fuming", "livid", "irate", "outraged", "infuriated",
        "terrible", "awful", "horrible", "dreadful", "pathetic", "useless", "worthless", "incompetent",
        "failure", "failed", "failing", "sucks", "sucked", "disaster", "catastrophe", "nightmare",
        "exhausted", "drained", "depleted", "burnt out", "burned out", "dead", "dying", "miserable",
        "stupid", "idiotic", "moronic", "dumb", "ridiculous", "absurd", "pointless", "waste",
        "blame", "fault", "screw up", "screwed", "messed up", "ruined",
        "quit", "quitting", "leaving", "done", "over it", "can't take", "give up", "resign",
        "damn", "hell", "crap", "shit", "fuck", "bullshit", "wtf",
        "worst", "worse", "inferior", "subpar", "mediocre", "disappointing", "underwhelming"
      ].join(", ")
    else
      [
        "love", "loved", "loving", "adore", "cherish", "delighted", "thrilled", "ecstatic", "elated",
        "amazing", "excellent", "fantastic", "wonderful", "perfect", "brilliant", "outstanding",
        "exceptional", "superb", "magnificent", "spectacular", "phenomenal", "incredible", "awesome",
        "best", "greatest", "superior", "optimal", "ideal", "flawless", "impeccable", "masterful",
        "genius", "brilliant", "star", "rockstar", "hero", "champion", "winner",
        "excited", "energized", "pumped", "motivated", "inspired", "passionate", "enthusiastic",
        "refreshed", "invigorated", "alive", "vibrant",
        "grateful", "thankful", "blessed", "fortunate", "lucky", "appreciated", "valued",
        "happy", "joyful", "cheerful", "pleased", "satisfied", "content", "fulfilled",
        "fun", "enjoyable", "pleasurable", "delightful",
        "beautiful", "gorgeous", "lovely", "charming", "elegant", "graceful", "splendid"
      ].join(", ")
    end

    <<~PROMPT
      Generate EXACTLY #{count} Slack workplace messages.

      CONTEXT:
      Signal: #{template.signal}
      Category: #{template.signal_category}

      #{polarity.upcase} INDICATOR TO DEMONSTRATE:
      #{indicator}

      DETAILED BEHAVIOR TO SHOW:
      #{description}

      #{cultural_impact_explanation}

      STRICT REQUIREMENTS:
      1. LENGTH: Each message must be #{length_type} (#{length_range})
      2. STYLE: #{style_type} - #{style_desc}
      3. ABSOLUTELY FORBIDDEN WORDS - DO NOT USE ANY OF THESE:
         #{forbidden_words}
      4. Each message must clearly demonstrate the #{polarity} CULTURAL IMPACT described above
      5. Messages must be realistic Slack workplace communication
      6. Remember: We're measuring CULTURAL IMPACT not emotional sentiment

      #{"For informal style, naturally include: lol, btw, fyi, asap, imo, tbh, idk, ngl, fr, and appropriate emojis 😅 👍 💪" if style_type == :informal}

      Generate EXACTLY #{count} examples. Number each (1., 2., etc.):
    PROMPT
  end

  def call_claude_api(prompt, api_key)
    uri = URI('https://api.anthropic.com/v1/messages')

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = HTTP_TIMEOUT

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = api_key
    request['anthropic-version'] = '2023-06-01'

    request.body = {
      model: "claude-opus-4-1-20250805",
      max_tokens: 2000,
      temperature: TEMPERATURE,
      messages: [{ role: "user", content: prompt }]
    }.to_json

    response = http.request(request)

    unless response.code == '200'
      error = JSON.parse(response.body) rescue response.body
      raise "Claude API Error #{response.code}: #{error}"
    end

    JSON.parse(response.body)
  end

  def parse_examples(response)
    content = response.dig('content', 0, 'text') || ''

    content.scan(/^\d+[\.\)]\s*(.+?)(?=^\d+[\.\)]|\z)/m)
      .flatten
      .map { |ex| ex.strip.gsub(/\s+/, ' ') }
      .reject(&:blank?)
  end

  def save_examples(template, examples_with_metadata, polarity)
    label = "#{template.signal_category.gsub(' ', '_')}_#{polarity.capitalize}"

    saved_count = 0
    examples_with_metadata.each do |example_data|
      Example.create!(
        template: template,
        label: label,
        message: "__label__#{label} #{example_data[:text]}",
        length_type: example_data[:length_type],
        style_type: example_data[:style_type],
        generated_at: example_data[:generated_at],
        verified: nil
      )
      saved_count += 1
    rescue => e
      puts "      Error saving: #{e.message}"
    end

    saved_count
  end

  # ================== VALIDATION METHODS ==================

  def validate_batch(examples, template, polarity, api_key)
    texts = examples.map { |ex| ex.message.sub(/^__label__\S+\s+/, '') }
    validation_prompt = build_validation_prompt(texts, template, polarity)
    response = call_claude_api(validation_prompt, api_key)
    results = parse_validation_response(response)

    validated_count = 0
    rejected_count = 0

    examples.each_with_index do |example, idx|
      is_valid = results[idx] || false
      example.update!(verified: is_valid)

      if is_valid
        validated_count += 1
      else
        rejected_count += 1
        report_rejection(example, template)
      end
    end

    [validated_count, rejected_count]
  end

  def build_validation_prompt(texts, template, polarity)
    cultural_definition = if polarity == 'positive'
      "POSITIVE = behaviors that build psychological safety, transparency, collaboration, engagement"
    else
      "NEGATIVE = behaviors that create silos, confusion, disengagement, mistrust"
    end

    <<~PROMPT
      Evaluate if these workplace messages demonstrate #{polarity} #{template.signal}.

      #{cultural_definition}

      Expected #{polarity} behavior: #{polarity == 'positive' ? template.positive_indicator : template.negative_indicator}

      For each message, respond ONLY with Y (correctly demonstrates #{polarity} cultural impact) or N (doesn't).

      MESSAGES:
      #{texts.map.with_index { |text, i| "#{i+1}. #{text}" }.join("\n")}

      Reply with ONLY Y or N for each, separated by commas. Example: Y,N,Y,Y,N
    PROMPT
  end

  def parse_validation_response(response)
    content = response.dig('content', 0, 'text') || ''
    results = content.strip.split(',').map(&:strip)
    results.map { |r| r.upcase == 'Y' }
  end

  def report_rejection(example, template)
    puts "\n  ❌ REJECTED EXAMPLE:"
    puts "     Signal: #{template.signal}"
    puts "     Category: #{template.signal_category}"
    puts "     Message: #{example.message.sub(/^__label__\S+\s+/, '')[0..100]}..."
    puts "     Reason: Did not demonstrate expected cultural impact"
  end
end
