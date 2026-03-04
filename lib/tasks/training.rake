# lib/tasks/generate_examples.rake
namespace :training do

  desc "Export messages to CSV with only message column"
  task messages: :environment do
    require 'csv'

    # Output file path
    output_file = Rails.root.join('messages.csv')

    # Counter for tracking
    exported = 0
    skipped = 0

    # Open CSV file for writing
    CSV.open(output_file, 'w') do |csv|
      # Write header
      csv << ['message']

      # Export messages with error handling for encryption issues
      Message.find_each do |message|
        begin
          # Access the 'text' field (not 'content')
          text = message.text

          # Skip empty messages
          next if text.blank?

          csv << [text]
          exported += 1

          # Show progress every 100 messages
          print "." if exported % 100 == 0

        rescue ActiveRecord::Encryption::Errors::Decryption => e
          # Handle decryption errors - skip this record
          skipped += 1
          print "x" if skipped % 10 == 0

        rescue => e
          # Handle any other errors
          puts "\n⚠️  Error processing message ID #{message.id}: #{e.message}"
          skipped += 1
        end
      end
    end

    puts "\n\n✅ Export complete!"
    puts "📁 File saved to: #{output_file}"
    puts "✓  Messages exported: #{exported}"
    puts "✗  Messages skipped (encryption/errors): #{skipped}" if skipped > 0
  end

  # Export only successfully decryptable recent messages
  desc "Export recent decryptable messages"
  task messages_recent: :environment do
    require 'csv'

    output_file = Rails.root.join('messages.csv')
    exported = 0
    skipped = 0

    # Use the recent scope and limit to last 30 days
    cutoff_date = 30.days.ago

    CSV.open(output_file, 'w') do |csv|
      csv << ['message']

      Message.recent.where("posted_at > ?", cutoff_date).find_each do |message|
        begin
          text = message.text
          next if text.blank?

          csv << [text]
          exported += 1
          print "." if exported % 100 == 0

        rescue ActiveRecord::Encryption::Errors::Decryption
          skipped += 1
        end
      end
    end

    puts "\n✅ Exported #{exported} recent messages (last 30 days)"
    puts "✗  Skipped #{skipped} messages" if skipped > 0
  end



  desc "Generate ML training examples for all signals"
  task generate: :environment do
    client = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))

    #Template.order("id ASC").offset(750).limit(50).each.with_index do |template, idx|
    Template.where("id in (701, 611, 751, 700)").each.with_index do |template, idx|

      puts "Processing signal #{idx + 1}: #{template.signal}..."

      # how many signals exist in this subcategory?
      signals_in_subcat = Template.where(signal_category: template.signal_category).count

      # target 600 examples per polarity for the whole subcategory
      examples_per_signal = (600.0 / signals_in_subcat).round

      ["Positive", "Negative"].each do |polarity|
        indicator = polarity == "Positive" ? template.positive_indicator : template.negative_indicator
        prompt = <<~PROMPT
          Write #{examples_per_signal} examples of Slack or Microsoft Teams messages that would indicate #{polarity} signals of "#{template.signal}" within the subcategory "#{template.signal_category}" within the submetric "#{template.sub_metric}" under the top-level metric "#{template.metric}".

          - Write messages 4–50 words long, 1–3 sentences each.
          - Mix professional and casual tones.
          - Make them realistic chat messages.
          - An example of #{polarity} #{template.signal} would be: #{indicator}.
          - Keep every message specific to "#{template.signal}".

          Output rules:
          - Output exactly #{examples_per_signal} lines, no more, no less.
          - Each line should only be the message text. Do not add labels, numbers, bullets, or explanations.
        PROMPT

        # --- Call GPT ---
        response = client.chat(
          parameters: {
            model: "gpt-4o-mini",
            messages: [{ role: "user", content: prompt }],
            temperature: 0.8,
            max_tokens: 2000
          }
        )

        raw_text = response.dig("choices", 0, "message", "content")
        unless raw_text
          puts "⚠️ No content returned for signal #{template.id} (#{polarity})"
          next
        end

        # --- Save full rows ---
        raw_text.lines.each do |line|
          msg_text = line.strip
          next if msg_text.blank?

          # Build full training row with prefix
          full_message = "__label__#{template.signal_category.gsub(" ", "_")}_#{polarity} #{msg_text}"

          Example.create!(
            template_id: template.id,
            label: template.signal, # just the signal
            message: full_message   # full training row
          )
        end

        puts "✅ Saved #{examples_per_signal} #{polarity} examples for signal #{template.id}"
        sleep 3 # rate limit safety
      end
    end
  end
end
