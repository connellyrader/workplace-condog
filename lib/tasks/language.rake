# lib/tasks/language.rake
# Rake tasks for language detection and translation

namespace :language do
  desc "Test language detection on sample texts"
  task test_detection: :environment do
    samples = [
      "Hello, how are you doing today?",
      "Szia, hogy vagy?",
      "Bonjour, comment allez-vous?",
      "Hola, ¿cómo estás?",
      "Guten Tag, wie geht es Ihnen?",
      "你好，你好吗？",
      "こんにちは、お元気ですか？",
      "Привет, как дела?",
      "مرحبا، كيف حالك؟",
      "שלום, מה שלומך?",
    ]

    puts "\n=== Language Detection Test ===\n\n"

    samples.each do |text|
      result = Language::Detector.detect_with_confidence(text)
      puts "#{text[0..40].ljust(45)} => #{result[:lang]} (#{(result[:confidence] * 100).round}% via #{result[:method]})"
    end

    puts "\n"
  end

  desc "Test translation pipeline"
  task test_translation: :environment do
    samples = [
      "Hello, how are you?",
      "Szia, hogy vagy?",
      "Guten Tag, wie geht es Ihnen?",
      "Bonjour, comment ça va?",
    ]

    puts "\n=== Translation Test ===\n\n"

    samples.each do |text|
      result = Language::Service.process_for_inference(text)

      puts "Original:   #{result[:original_text]}"
      puts "Language:   #{result[:source_lang]} (#{(result[:detection_confidence] * 100).round}%)"
      puts "Translated: #{result[:was_translated] ? result[:text] : '(skipped - already English)'}"
      puts "Cached:     #{result[:translation_cached] || 'n/a'}"
      puts "-" * 50
    end

    puts "\n"
  end

  desc "Show translation cache stats"
  task cache_stats: :environment do
    stats = Language::Service.translation_stats
    puts "\n=== Translation Stats ===\n"
    puts "Cache enabled: #{stats[:cache_enabled]}"
    puts "Model: #{stats[:model]}"
    puts "\n"
  end

  desc "Clear translation cache"
  task clear_cache: :environment do
    puts "Clearing translation cache..."
    Language::Translator.clear_cache!
    puts "Done."
  end

  desc "Detect language for a specific message ID"
  task :detect_message, [:message_id] => :environment do |_, args|
    message = Message.find(args[:message_id])
    text = message.text || message.plaintext || message.decrypted_text

    puts "\n=== Message ##{message.id} ===\n"
    puts "Text: #{text[0..200]}#{'...' if text.length > 200}"
    puts ""

    result = Language::Service.process_for_inference(text)
    puts "Language: #{result[:source_lang]}"
    puts "Confidence: #{(result[:detection_confidence] * 100).round}%"
    puts "Method: #{result[:detection_method]}"
    puts "Needs translation: #{result[:was_translated]}"

    if result[:was_translated]
      puts "Translated: #{result[:text][0..200]}#{'...' if result[:text].length > 200}"
    end

    puts "\n"
  end

  desc "Analyze language distribution for a workspace"
  task :workspace_distribution, [:workspace_id] => :environment do |_, args|
    workspace_id = args[:workspace_id]

    puts "\n=== Language Distribution (Workspace #{workspace_id}) ===\n"
    puts "Sampling last 1000 messages...\n"

    messages = Message
      .joins(:integration)
      .where(integrations: { workspace_id: workspace_id })
      .where.not(text: [nil, ""])
      .order(id: :desc)
      .limit(1000)

    distribution = Hash.new(0)

    messages.each do |msg|
      text = msg.text || msg.plaintext || ""
      next if text.strip.empty?

      lang = Language::Detector.detect(text)
      distribution[lang] += 1
    end

    total = distribution.values.sum
    distribution.sort_by { |_, count| -count }.each do |lang, count|
      pct = (count.to_f / total * 100).round(1)
      puts "#{lang.upcase.ljust(5)} #{count.to_s.rjust(5)} (#{pct}%)"
    end

    non_english = total - distribution["en"]
    puts "\n"
    puts "Total sampled: #{total}"
    puts "Non-English: #{non_english} (#{(non_english.to_f / total * 100).round(1)}%)"
    puts "Est. monthly translation cost: $#{estimate_monthly_cost(non_english, total)}"
    puts "\n"
  end

  def estimate_monthly_cost(non_english_sample, total_sample)
    return 0 if total_sample == 0

    non_english_ratio = non_english_sample.to_f / total_sample
    # Assume ~30k messages/month for a 50-person company
    # GPT-4o-mini: ~$0.15/1M input, $0.60/1M output
    # Avg translation: 1000 input tokens, 100 output tokens
    estimated_translations = 30_000 * non_english_ratio
    input_cost = (estimated_translations * 1000 / 1_000_000.0) * 0.15
    output_cost = (estimated_translations * 100 / 1_000_000.0) * 0.60
    (input_cost + output_cost).round(2)
  end
end
