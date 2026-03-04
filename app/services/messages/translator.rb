# frozen_string_literal: true

# Messages::Translator
#
# Detects non-English text and translates it to English using OpenAI.
# Returns a hash with :text (always English), :text_original (if translated), and :original_language.
#
# Usage:
#   result = Messages::Translator.translate("Bonjour, comment ça va?")
#   # => { text: "Hello, how are you?", text_original: "Bonjour, comment ça va?", original_language: "fr" }
#
#   result = Messages::Translator.translate("Hello, how are you?")
#   # => { text: "Hello, how are you?", text_original: nil, original_language: nil }
#
module Messages
  class Translator
    # Model to use for translation - gpt-4o-mini is fast and cheap
    MODEL = ENV.fetch("TRANSLATION_MODEL", "gpt-4o-mini")

    # Skip translation for very short messages (likely not enough context)
    MIN_LENGTH_FOR_TRANSLATION = 10

    # Languages we consider "English enough" to skip translation
    ENGLISH_CODES = %w[en en-US en-GB en-AU en-CA].freeze

    class << self
      # Main entry point: takes raw text, returns translated result hash
      def translate(text)
        return english_result(text) if text.blank?
        return english_result(text) if text.length < MIN_LENGTH_FOR_TRANSLATION

        # Detect language and translate if needed
        detection = detect_and_translate(text)

        if detection[:is_english]
          english_result(text)
        else
          {
            text: detection[:translated_text],
            text_original: text,
            original_language: detection[:language]
          }
        end
      rescue => e
        Rails.logger.error("[Messages::Translator] translation failed: #{e.class}: #{e.message}")
        # On any error, fall back to storing the original text as-is
        english_result(text)
      end

      private

      def english_result(text)
        # Always tag with 'en' so we know detection ran (not just unprocessed)
        { text: text, text_original: nil, original_language: "en" }
      end

      def detect_and_translate(text)
        client = OpenAI::Client.new

        response = client.chat(
          parameters: {
            model: MODEL,
            temperature: 0.1,
            max_tokens: text.length * 3, # Allow enough room for translation + metadata
            messages: [
              {
                role: "system",
                content: system_prompt
              },
              {
                role: "user",
                content: text
              }
            ]
          }
        )

        content = response.dig("choices", 0, "message", "content").to_s.strip
        parse_response(content, text)
      end

      def system_prompt
        <<~PROMPT.strip
          You are a language detection and translation assistant.
          
          Analyze the user's message and respond in this exact JSON format:
          {"lang":"XX","en":"translated text here"}
          
          Rules:
          - "lang" is the ISO 639-1 code (e.g., "en", "fr", "es", "de", "zh", "ja", "ko", "pt", "it", "ru")
          - If the text is already in English, set "lang":"en" and "en" to the original text unchanged
          - If the text is not English, translate it to natural English and put the translation in "en"
          - Preserve the meaning and tone of the original message
          - Do not add any explanation, just output the JSON
          - Handle mixed-language messages by translating non-English parts
        PROMPT
      end

      def parse_response(content, original_text)
        # Try to parse as JSON
        # Handle cases where the model might wrap in markdown code blocks
        json_str = content.gsub(/\A```json\s*/, "").gsub(/\s*```\z/, "").strip

        parsed = JSON.parse(json_str)
        lang = parsed["lang"].to_s.downcase.strip
        translated = parsed["en"].to_s.strip

        # Sanity check: if translation is empty, use original
        translated = original_text if translated.blank?

        {
          is_english: ENGLISH_CODES.include?(lang) || lang == "en",
          language: lang.presence,
          translated_text: translated
        }
      rescue JSON::ParserError => e
        Rails.logger.warn("[Messages::Translator] JSON parse failed, content=#{content.inspect}: #{e.message}")
        # If we can't parse, assume English to avoid data loss
        { is_english: true, language: nil, translated_text: original_text }
      end
    end
  end
end
