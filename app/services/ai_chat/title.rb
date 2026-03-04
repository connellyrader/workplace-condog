# frozen_string_literal: true
module AiChat
  class Title
    DEFAULT_MAX = (ENV.fetch("AI_CHAT_TITLE_MAX", "80").to_i)

    def self.from_text(text, max: DEFAULT_MAX)
      raw = text.to_s
      return "New conversation" if raw.strip.empty?

      # Take first line, strip common markdown bullets/headings, collapse spaces
      line = raw.split(/\r?\n/, 2).first.to_s
      line = line.sub(/\A[#>\-\*\d\.\)\s]+/, '').strip
      line = line.gsub(/\s+/, ' ')
      return "New conversation" if line.empty?

      truncated = line[0, max].rstrip
      truncated += "…" if line.length > truncated.length
      truncated
    end
  end
end
