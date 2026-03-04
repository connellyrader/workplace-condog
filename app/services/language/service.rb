# app/services/language/service.rb
# Main entry point for language processing.
# Combines detection and translation into a single interface.
#
# Usage:
#   # Process text for inference (detect + translate if needed)
#   result = Language::Service.process_for_inference("Szia, hogy vagy?")
#   result[:text]           # => "Hi, how are you?" (English for inference)
#   result[:original_text]  # => "Szia, hogy vagy?"
#   result[:source_lang]    # => "hu"
#   result[:was_translated] # => true
#
#   # Just detect language
#   Language::Service.detect("Hello world")  # => "en"
#
#   # Check if English
#   Language::Service.english?("Hello world")  # => true

module Language
  class Service
    class << self
      # Process text for inference pipeline
      # Returns normalized text ready for ML model, plus metadata
      def process_for_inference(text)
        return empty_result if text.nil? || text.strip.empty?

        text = text.strip
        
        # Detect language (free, instant)
        detection = Detector.detect_with_confidence(text)
        source_lang = detection[:lang]
        
        # If English, no translation needed
        if source_lang == "en"
          return {
            text: text,
            original_text: text,
            source_lang: "en",
            was_translated: false,
            detection_confidence: detection[:confidence],
            detection_method: detection[:method]
          }
        end
        
        # Non-English: translate
        translation = Translator.to_english(text, source_lang: source_lang)
        
        {
          text: translation[:translated],
          original_text: text,
          source_lang: source_lang,
          was_translated: true,
          translation_cached: translation[:cached],
          detection_confidence: detection[:confidence],
          detection_method: detection[:method],
          translation_error: translation[:error]
        }
      end
      
      # Simple detection
      def detect(text)
        Detector.detect(text)
      end
      
      # Detection with confidence
      def detect_with_confidence(text)
        Detector.detect_with_confidence(text)
      end
      
      # English check
      def english?(text)
        Detector.english?(text)
      end
      
      # Translate to English
      def translate(text, source_lang: nil)
        Translator.to_english(text, source_lang: source_lang)
      end
      
      # Stats for monitoring
      def translation_stats
        # Could be expanded to track hit rates, costs, etc.
        {
          cache_enabled: Rails.cache.present?,
          model: Translator::MODEL
        }
      end
      
      private
      
      def empty_result
        {
          text: "",
          original_text: "",
          source_lang: "en",
          was_translated: false,
          detection_confidence: 1.0,
          detection_method: "empty"
        }
      end
    end
  end
end
