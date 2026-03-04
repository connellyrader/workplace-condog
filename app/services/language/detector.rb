# frozen_string_literal: true

# app/services/language/detector.rb
#
# Language detection using Google's CLD3 (Compact Language Detector 3).
# Offline, free, highly accurate (96%+ on short text, 99%+ on longer text).
# Supports 100+ languages including Hungarian, German, Spanish, etc.
#
# Usage:
#   Language::Detector.detect("Hello world")  # => "en"
#   Language::Detector.detect("Szia, hogy vagy?")  # => "hu"
#   Language::Detector.detect("你好世界")  # => "zh"
#   Language::Detector.english?("Hello world")  # => true

require "cld3"

module Language
  class Detector
    # CLD3 identifier instance (min_bytes=0, max_bytes=1000)
    # Thread-safe, can be shared across requests
    IDENTIFIER = CLD3::NNetLanguageIdentifier.new(0, 1000)

    # Minimum text length for reliable detection
    MIN_LENGTH = 10

    class << self
      # Detect language of text, returns ISO 639-1 code (2-letter string)
      # Returns "en" for empty/short text or when detection is unreliable
      def detect(text)
        return "en" if text.nil? || text.to_s.strip.length < MIN_LENGTH

        result = IDENTIFIER.find_language(text.to_s)

        # CLD3 returns a struct with methods: language (symbol), probability, reliable?
        if result.reliable?
          # Convert symbol to string (e.g., :hu -> "hu")
          result.language.to_s
        else
          # Unreliable detection - default to English
          "en"
        end
      rescue => e
        Rails.logger.warn("[Language::Detector] detection failed: #{e.message}")
        "en"
      end

      def english?(text)
        detect(text) == "en"
      end

      def non_english?(text)
        !english?(text)
      end

      # Returns language code, probability, and reliability for debugging
      def detect_with_confidence(text)
        return { lang: "en", confidence: 1.0, reliable: true, method: "empty" } if text.nil? || text.to_s.strip.length < MIN_LENGTH

        result = IDENTIFIER.find_language(text.to_s)

        {
          lang: result.language.to_s,
          confidence: result.probability,
          reliable: result.reliable?,
          method: "cld3"
        }
      rescue => e
        Rails.logger.warn("[Language::Detector] detection failed: #{e.message}")
        { lang: "en", confidence: 0.0, reliable: false, method: "error" }
      end

      # Detect top N possible languages (useful for mixed-language text)
      def detect_top_n(text, n = 3)
        return [{ lang: "en", confidence: 1.0, reliable: true }] if text.nil? || text.to_s.strip.length < MIN_LENGTH

        results = IDENTIFIER.find_top_n_most_freq_langs(text.to_s, n)

        results.map do |r|
          {
            lang: r.language.to_s,
            confidence: r.probability,
            reliable: r.reliable?
          }
        end
      rescue => e
        Rails.logger.warn("[Language::Detector] detection failed: #{e.message}")
        [{ lang: "en", confidence: 0.0, reliable: false }]
      end
    end
  end
end
