# app/services/language/translator.rb
# Translates non-English text to English using GPT.
# Uses caching to avoid re-translating identical text.
#
# Usage:
#   Language::Translator.to_english("Szia, hogy vagy?")
#   # => { original: "Szia, hogy vagy?", translated: "Hi, how are you?", 
#   #      source_lang: "hu", cached: false }
#
# Caching:
#   - Uses Rails cache with configurable TTL
#   - Cache key is hash of original text
#   - Set TRANSLATION_CACHE_TTL env var (default: 30 days)

module Language
  class Translator
    CACHE_PREFIX = "lang_translation"
    DEFAULT_CACHE_TTL = 30.days
    
    # Use GPT-4o-mini for cost efficiency - translation is a simple task
    MODEL = "gpt-4o-mini"
    
    class << self
      def to_english(text, source_lang: nil)
        return empty_result(text) if text.nil? || text.strip.empty?

        text = text.to_s.strip
        
        # Detect language if not provided
        source_lang ||= Detector.detect(text)
        
        # Skip translation if already English
        if source_lang == "en"
          return {
            original: text,
            translated: text,
            source_lang: "en",
            cached: false,
            skipped: true
          }
        end
        
        # Check cache first
        cache_key = build_cache_key(text)
        cached = Rails.cache.read(cache_key)
        
        if cached
          return {
            original: text,
            translated: cached[:translated],
            source_lang: cached[:source_lang] || source_lang,
            cached: true
          }
        end
        
        # Call GPT for translation
        translated = translate_via_gpt(text, source_lang)
        
        # Cache the result
        Rails.cache.write(cache_key, { translated: translated, source_lang: source_lang }, expires_in: cache_ttl)
        
        {
          original: text,
          translated: translated,
          source_lang: source_lang,
          cached: false
        }
      rescue => e
        Rails.logger.error("[Language::Translator] Error translating: #{e.class} #{e.message}")
        
        # On error, return original text so processing can continue
        {
          original: text,
          translated: text,
          source_lang: source_lang,
          cached: false,
          error: e.message
        }
      end
      
      # Batch translate multiple texts (more efficient for bulk processing)
      def batch_to_english(texts)
        texts.map { |text| to_english(text) }
      end
      
      # Check if translation is needed (useful for pre-filtering)
      def needs_translation?(text)
        Detector.non_english?(text)
      end
      
      # Clear translation cache (useful for testing or if translations need refresh)
      def clear_cache!
        # This clears all translation cache entries
        # In production, you might want a more targeted approach
        Rails.cache.delete_matched("#{CACHE_PREFIX}:*")
      end
      
      private
      
      def empty_result(text)
        {
          original: text.to_s,
          translated: text.to_s,
          source_lang: "en",
          cached: false,
          skipped: true
        }
      end
      
      def build_cache_key(text)
        # Use MD5 hash of text as cache key (fast, no collision concerns for this use case)
        hash = Digest::MD5.hexdigest(text)
        "#{CACHE_PREFIX}:#{hash}"
      end
      
      def cache_ttl
        ENV.fetch("TRANSLATION_CACHE_TTL", DEFAULT_CACHE_TTL.to_i).to_i.seconds
      end
      
      def translate_via_gpt(text, source_lang)
        client = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))
        
        lang_name = language_name(source_lang)
        
        response = client.chat(
          parameters: {
            model: MODEL,
            messages: [
              {
                role: "system",
                content: "You are a translator. Translate the following #{lang_name} text to English. " \
                         "Output ONLY the translated text, nothing else. " \
                         "Preserve the tone and meaning as closely as possible."
              },
              {
                role: "user",
                content: text
              }
            ],
            max_tokens: [text.length * 2, 1000].max,  # Allow some expansion
            temperature: 0.1  # Low temperature for consistent translations
          }
        )
        
        translated = response.dig("choices", 0, "message", "content")&.strip
        
        if translated.blank?
          Rails.logger.warn("[Language::Translator] Empty response from GPT for: #{text[0..50]}...")
          return text  # Fall back to original
        end
        
        # Log translation for debugging/monitoring
        Rails.logger.info("[Language::Translator] #{source_lang}->en: \"#{text[0..30]}...\" => \"#{translated[0..30]}...\"")
        
        translated
      end
      
      def language_name(code)
        LANGUAGE_NAMES[code] || code.upcase
      end
      
      LANGUAGE_NAMES = {
        "zh" => "Chinese",
        "ja" => "Japanese",
        "ko" => "Korean",
        "ar" => "Arabic",
        "he" => "Hebrew",
        "ru" => "Russian",
        "th" => "Thai",
        "el" => "Greek",
        "hi" => "Hindi",
        "ta" => "Tamil",
        "bn" => "Bengali",
        "en" => "English",
        "es" => "Spanish",
        "fr" => "French",
        "de" => "German",
        "pt" => "Portuguese",
        "it" => "Italian",
        "nl" => "Dutch",
        "pl" => "Polish",
        "hu" => "Hungarian",
        "ro" => "Romanian",
        "cs" => "Czech",
        "sv" => "Swedish",
        "da" => "Danish",
        "fi" => "Finnish",
        "no" => "Norwegian",
        "tr" => "Turkish",
      }.freeze
    end
  end
end
