# lib/tasks/import_fasttext_examples.rake
namespace :import do
  desc "Import fastText examples. FILE=path/to/file.txt [BATCH=1000] [DRY_RUN=1]"
  task fasttext: :environment do
    file  = ENV["FILE"]  or abort "ERROR: Provide FILE=path/to/file.txt"
    batch = (ENV["BATCH"] || 1000).to_i
    dry   = ENV["DRY_RUN"].to_s == "1"

    abort "ERROR: FILE not found: #{file}" unless File.exist?(file)

    # --- helpers ---
    def strip_polarity(label_with_pol)
      # remove final _Positive/_Negative (case-insensitive)
      label_with_pol.to_s.sub(/_(?:Positive|Negative)\z/i, "")
    end

    def label_to_signal_category(label_with_pol)
      # "__label__Support_Resources_Negative" -> "Support Resources"
      base = strip_polarity(label_with_pol)
      base.tr("_", " ")
    end

    def say(msg) = puts "[examples:import_fasttext] #{msg}"

    # Build lookup map from templates.signal_category (case-insensitive) -> id
    say "Loading templates…"
    template_map = {}
    Template.find_each do |t|
      next if t.signal_category.blank?
      key = t.signal_category.strip.downcase
      template_map[key] ||= t.id
    end
    say "Templates loaded: #{template_map.size} unique signal_category keys."

    total_lines    = 0
    imported_count = 0
    skipped_parse  = 0
    skipped_nomap  = 0
    buffer = []

    # returns [full_label, human_category, message_text] or nil
    parse_line = lambda do |line|
      s = line&.strip
      return nil if s.blank?

      # capture the FIRST fastText label; keep rest as message
      if s =~ /^__label__([^\s]+)\s+(.+)\z/
        full_label = Regexp.last_match(1) # e.g., "Support_Resources_Negative"
        msg_text   = Regexp.last_match(2)

        human_cat = label_to_signal_category(full_label) # "Support Resources"
        [full_label, human_cat, msg_text]
      else
        nil
      end
    end

    say "Reading: #{file}"
    File.foreach(file) do |line|
      total_lines += 1
      parsed = parse_line.call(line)
      unless parsed
        skipped_parse += 1
        next
      end

      full_label, human_cat, _msg_text = parsed
      # case-insensitive match against templates.signal_category
      template_id = template_map[human_cat.downcase]

      unless template_id
        skipped_nomap += 1
        next
      end

      buffer << {
        template_id: template_id,
        label:       full_label,      # store label with polarity
        message:     line.rstrip,     # store entire original fastText line
        created_at:  Time.current,
        updated_at:  Time.current,
      }

      if buffer.size >= batch
        if dry
          imported_count += buffer.size
        else
          Example.insert_all(buffer)
          imported_count += buffer.size
        end
        buffer.clear
      end
    end

    # flush remainder
    if buffer.any?
      if dry
        imported_count += buffer.size
      else
        Example.insert_all(buffer)
        imported_count += buffer.size
      end
      buffer.clear
    end

    say "Done."
    say "Total lines:   #{total_lines}"
    say "Imported:      #{imported_count} #{'(dry run)' if dry}"
    say "Skipped parse: #{skipped_parse}"
    say "No template:   #{skipped_nomap}"
  end
end
